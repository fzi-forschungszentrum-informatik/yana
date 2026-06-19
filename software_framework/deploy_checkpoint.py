import argparse
import os
import re

import nir
import numpy as np
import torch

from qtorch import FixedPoint
from qtorch.quant import Quantizer

from yana.core.config import AcceleratorConfig
from yana.core.logging import set_log_level, LogLevel
from yana.deploy import (
    Accelerator, generate_input_events,
    write_accelerator_memories,
    write_input_events,
    write_output_trace,
    allocate_run_dir,
    collect_train_samples,
    write_sample_info,
)
from yana.train.config import Cfg
from yana.train.model import Model
from yana.train.training import initialize_experiment, apply_pruning_masks
from yana.train.utils.nir_utils import export_nir as _export_nir


def quantize_weights(model: Model, quant_wl: int, quant_fl: int):
    weight_quantizer = Quantizer(FixedPoint(wl=quant_wl, fl=quant_fl), forward_rounding="nearest")
    quantized_weights = model.state_dict()
    for name, param in quantized_weights.items():
        if "weight" in name:
            quantized_weights[name] = weight_quantizer(param)
    model.load_state_dict(quantized_weights)


def _crop_sequence(seq: np.ndarray, crop_ts: int) -> np.ndarray:
    if crop_ts > 0:
        return seq[:crop_ts]
    return seq


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Load a checkpoint, export NIR, simulate and generate deployment files.")
    parser.add_argument("-C", "--checkpoint-dir", type=str, required=True, help="Path to training run directory containing parsed_config.yaml and checkpoints/.")
    parser.add_argument("-a", "--accelerator-config-path", type=str, default="yana/core/config/default/accelerator.yaml", help="Override path to accelerator config YAML.")
    parser.add_argument("-o", "--output-path", type=str, default=None, help="Deploy root folder (default: {checkpoint-dir}/deploy).")
    parser.add_argument("-n", "--num-samples", type=int, default=1, help="Number of trainset samples to export (default: 1).")
    parser.add_argument("-e", "--experiment-name", type=str, default=None, help="Override the auto-generated output directory name (e.g. shd_0). When set, this exact name is used and no integer suffix is appended.")
    parser.add_argument("--ckpt", type=str, default=None, help="Exact checkpoint to use: a filename within the run's checkpoints/ dir or an absolute path. For pruned runs this overrides the default highest-sparsity selection.")
    parser.add_argument("--no-fatal", action="store_true", help="Disable strict checking of accelerator constraints.")
    parser.add_argument("--no-validate-neuron-params", action="store_true", help="Disable checking of neuron parameters.")
    parser.add_argument("--crop-ts", type=int, default=-1, help="Crop the number of timesteps used for simulation and export.")
    parser.add_argument("--verbose", action="store_true", help="Print per-timestep sim/ref comparison table.")
    args = parser.parse_args()

    ckpt_dir = args.checkpoint_dir if os.path.isabs(args.checkpoint_dir) else os.path.join(os.getcwd(), args.checkpoint_dir)
    checkpoints_dir = os.path.join(ckpt_dir, "checkpoints")
    ckpt_files = sorted(f for f in os.listdir(checkpoints_dir) if f.endswith(".ckpt"))
    assert ckpt_files, f"No checkpoint found in {checkpoints_dir}"

    # A pruned run stores one best checkpoint per sparsity increment, each named
    # with its target sparsity (e.g. "sparsity=0.50-...ckpt").
    sparsity_of = {}
    for f in ckpt_files:
        match = re.search(r"sparsity=([0-9]*\.?[0-9]+)", f)
        if match:
            sparsity_of[f] = float(match.group(1))
    is_pruned = bool(sparsity_of)

    if args.ckpt is not None:
        ckpt_path = args.ckpt if os.path.isabs(args.ckpt) else os.path.join(checkpoints_dir, args.ckpt)
        assert os.path.isfile(ckpt_path), f"Specified checkpoint not found: {ckpt_path}"
        match = re.search(r"sparsity=([0-9]*\.?[0-9]+)", os.path.basename(ckpt_path))
        selected_sparsity = float(match.group(1)) if match else None
    elif is_pruned:
        # Default to the highest available sparsity for a pruned run.
        best_file = max(sparsity_of, key=lambda f: sparsity_of[f])
        ckpt_path = os.path.join(checkpoints_dir, best_file)
        selected_sparsity = sparsity_of[best_file]
        print(f"Detected pruned run. Using highest sparsity checkpoint ({selected_sparsity:.1%}): {best_file}")
    else:
        ckpt_path = (
            os.path.join(checkpoints_dir, "last.ckpt")
            if os.path.isfile(os.path.join(checkpoints_dir, "last.ckpt"))
            else os.path.join(checkpoints_dir, ckpt_files[0])
        )
        selected_sparsity = None
    cfg_path = os.path.join(ckpt_dir, "parsed_config.yaml")
    assert os.path.isfile(cfg_path), f"Config not found: {cfg_path}"

    if args.output_path is None:
        deploy_root = os.path.join(ckpt_dir, "deploy")
    elif os.path.isabs(args.output_path):
        deploy_root = args.output_path
    else:
        deploy_root = os.path.join(os.getcwd(), args.output_path)

    acc_cfg_path = args.accelerator_config_path if os.path.isabs(args.accelerator_config_path) else os.path.join(os.getcwd(), args.accelerator_config_path)
    acc_cfg = AcceleratorConfig.from_yaml(acc_cfg_path)
    assert acc_cfg.core_config_hidden is not None, "Hidden core config is required."
    quant_config = acc_cfg.core_config_hidden.quant_config

    # Load model from checkpoint
    cfg = Cfg.from_yaml(cfg_path)
    cfg.trainer_cfg.checkpoint_path = ckpt_path
    print(f"Loading checkpoint: {ckpt_path}")
    _, model, data_module = initialize_experiment(cfg, acc_cfg, enable_logs=False)
    model.eval()

    # Bake pruning masks into the weights before deployment.
    num_masks = apply_pruning_masks(model)
    if num_masks:
        print(f"Applied {num_masks} pruning mask(s) to weights.")

    print("Quantizing model weights...")
    quantize_weights(model, quant_config.format_weights.word_length, quant_config.format_weights.fraction_length)

    # Allocate versioned run directory
    dataset_name = cfg.trainer_cfg.dataset_cfg.dataset
    if selected_sparsity is not None:
        # e.g. 80% sparsity -> "shd_pruned_80"
        sparsity_tag = f"{round(selected_sparsity * 100)}"
        dataset_name = f"{dataset_name}_pruned_{sparsity_tag}"
    run_dir = allocate_run_dir(deploy_root, dataset_name, args.experiment_name)
    init_dir = os.path.join(run_dir, "init")
    dataset_dir = os.path.join(run_dir, "dataset")
    print(f"Export run directory: {run_dir}")

    # Collect samples from training set
    samples = collect_train_samples(
        data_module.trainset, args.num_samples, cfg.trainer_cfg.random_seed,
    )
    print(f"Exporting {len(samples)} sample(s) from training set")

    # Export NIR (use first frame of first sample for graph tracing)
    first_seq = _crop_sequence(samples[0][0], args.crop_ts)
    trace_sample = torch.tensor(first_seq[0:1], dtype=torch.float32)

    nir_output_file = os.path.join(run_dir, "nir_file.nir")
    metadata = {"accelerator_config": acc_cfg.to_dict()}
    _export_nir(model.network, metadata, nir_output_file, trace_sample, dt=cfg.model_cfg.network_cfg.dt)

    # Create accelerator from exported NIR
    nir_graph = nir.read(nir_output_file)
    accelerator = Accelerator(
        nir_graph=nir_graph,
        acc_config=acc_cfg,
        constraints_fatal=not args.no_fatal,
        validate_neuron_params=not args.no_validate_neuron_params
    )
    accelerator.print_summary()

    state_width = accelerator.output_core.config.quant_config.format_state.word_length
    samples_meta = []

    # The accelerator updates all cores in lock-step and dispatches spikes
    # afterwards, so each routing hop adds one timestep of latency. The output
    # core therefore lags the input by its routing depth, and the simulation
    # must run that many extra timesteps for the final input frame to reach it.
    network_depth = accelerator.network_depth()[accelerator.output_core.id]

    set_log_level(LogLevel.WARNING)
    col_w = 12

    for sample_idx, (seq, target) in enumerate(samples):
        seq = _crop_sequence(seq, args.crop_ts)
        input_file = f"sample_{sample_idx}.txt"
        output_file = f"neuron_state_trace_{sample_idx}.txt"

        input_events = generate_input_events(seq)
        # Run long enough for the last input frame to propagate through every
        # routing hop to the output core (one extra timestep per hop).
        simulation_duration = len(seq) + network_depth
        accelerator.reset()
        accelerator.run(input_events, simulation_duration)
        output_states = accelerator.get_output_states()

        write_input_events(input_events, dataset_dir, acc_cfg, filename=input_file)
        write_output_trace(output_states, dataset_dir, state_width, filename=output_file)

        samples_meta.append({
            "target": target,
            "input_file": input_file,
            "output_file": output_file,
        })

        # Per-timestep comparison against live model inference
        input_tensor = torch.tensor(seq, dtype=torch.float32)
        ref_states_per_ts = []
        with torch.no_grad():
            model.network.reset()
            for frame in input_tensor:
                out = model.network(frame.unsqueeze(0))
                ref_states_per_ts.append(out.squeeze(0).numpy())
        ref_neuron_states = np.array(ref_states_per_ts)  # [T, out_features]

        sim_ts_sorted = sorted(output_states.keys())
        offset = len(sim_ts_sorted) - len(ref_neuron_states)

        n_neurons = ref_neuron_states.shape[1]
        max_differences = []
        rows = []
        for ref_idx, ref_output in enumerate(ref_neuron_states):
            sim_ts = sim_ts_sorted[offset + ref_idx]
            sim_output = np.array([state.to_float() for state in output_states[sim_ts]])
            diffs = np.abs(sim_output - ref_output)
            max_differences.append(np.max(diffs))
            rows.append((ref_idx, sim_output, ref_output, diffs))

        if args.verbose:
            neuron_labels = "      | " + " ".join(f"{'neuron ' + str(i):^{3*col_w+2}}" for i in range(n_neurons))
            comparison_header = f"{'ts':>5} | " + " ".join(f"{'sim':>{col_w}} {'ref':>{col_w}} {'diff':>{col_w}}" for _ in range(n_neurons))
            print(f"\n--- Sample {sample_idx} (target={target}) ---")
            print(neuron_labels)
            print(comparison_header)
            print("-" * len(comparison_header))
            for ref_idx, sim_output, ref_output, diffs in rows:
                row = f"{ref_idx:>5} | " + " ".join(
                    f"{sim_output[i]:>{col_w}.6f} {ref_output[i]:>{col_w}.6f} {diffs[i]:>{col_w}.6f}"
                    for i in range(n_neurons)
                )
                print(row)

        print(f"Sample {sample_idx} (target={target}): max difference = {max(max_differences):.6f}")

    write_sample_info(dataset_dir, samples_meta)
    write_accelerator_memories(accelerator, init_dir, acc_cfg, as_events=True)

    print(f"\nDeployment files written to {run_dir}")
