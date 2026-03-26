import argparse
import tarfile
import tempfile
import os
import sys
from tqdm import tqdm

import nir
from qtorch.quant import Quantizer
from qtorch import FixedPoint
import torch
from torch.utils.data import random_split
import numpy as np
import yaml

from yana.train.config import load_yaml
from yana.train.model import Model
from yana.train.training import initialize_experiment
from yana.train.utils import export_nir
from yana.deploy.network import Network, LogLevel, generate_input_events
from yana.deploy.fixed_point import int_to_binary_str
from yana.core.hardware_config import from_metadata
from yana.core.quant_options import options_from_config

import logging


class SuppressOutput:
    '''Context manager for temporarily suppressing all output.'''
    def __enter__(self):
        self._original_stdout = sys.stdout
        self._original_stderr = sys.stderr
        self._original_log_level = logging.getLogger("pytorch_lightning").getEffectiveLevel()
        sys.stdout = open(os.devnull, 'w')
        sys.stderr = open(os.devnull, 'w')
        logging.getLogger("pytorch_lightning").setLevel(logging.ERROR)
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        sys.stdout.close()
        sys.stderr.close()
        sys.stdout = self._original_stdout
        sys.stderr = self._original_stderr
        logging.getLogger("pytorch_lightning").setLevel(self._original_log_level)

    def print(self, *values: object):
        print(*values, file=self._original_stdout)


def quantize_weights(model: Model, quant_wl: int, quant_fl: int):
    # Check if weights are in the fixed point format's bounds
    integer_bits = quant_wl - quant_fl
    min_value = -2 ** (integer_bits - 1)
    max_value = 2 ** (integer_bits - 1) - 2 ** (-quant_fl)

    max_weight = float('-inf')
    min_weight = float('inf')

    for name, module in model.network.named_modules():
        if hasattr(module, 'weight'):
            max_weight = max(max_weight, module.weight.max())   # type: ignore
            min_weight = min(min_weight, module.weight.min())   # type: ignore

    if max_weight > max_value:
        print(
            f"Maximum weight value in network ({max_weight}) exceeds the representable fixed point range: {min_value} to {max_value}\n"
            "Network performance will suffer from clamping the weight values."
        )
    if min_weight < min_value:
        print(
            f"Minimum weight value in network ({min_weight}) exceeds the representable fixed point range: {min_value} to {max_value}\n"
            "Network performance will suffer from clamping the weight values."
        )

    # Quantize weights
    weight_quantizer = Quantizer(FixedPoint(wl=quant_wl, fl=quant_fl), forward_rounding="nearest")
    quantized_weights = model.state_dict()
    for name, param in quantized_weights.items():
        if "weight" in name:
            quantized_weights[name] = weight_quantizer(param)
    model.load_state_dict(quantized_weights)

    return model


def export_input_data(data_module, num_samples, output_path):
    test_set = data_module.test_dataloader().dataset
    os.makedirs(output_path, exist_ok=True)

    # Ensure num_samples is not greater than the total number of samples
    total_samples = len(test_set)
    if num_samples > total_samples:
        num_samples = total_samples

    # Choose random samples from test dataset and format
    samples, _ = random_split(test_set, [num_samples, total_samples - num_samples])
    sample_loader = torch.utils.data.DataLoader(samples, batch_size=num_samples)
    sample_batch_data, sample_batch_targets = next(iter(sample_loader))
    sample_batch_data = sample_batch_data.permute([1, 0, 2, 3, 4])

    sample_info_dict = {}

    # Save samples to disk
    for idx in range(num_samples):
        sample_name = f"sample_{idx}"
        sample_info_dict[idx] = {
            "target": sample_batch_targets[idx].item(),
            "file": f"{sample_name}.txt"
        }

        sample_file = os.path.join(output_path, f"{sample_name}.npy")
        np.save(sample_file, sample_batch_data[:, idx].cpu().detach().numpy())

    sample_info_file = os.path.join(output_path, "sample_info.yaml")
    with open(sample_info_file, "w") as f:
        yaml.safe_dump(sample_info_dict, f)

    return sample_batch_data


def training_export(dataset_type: str, num_samples: int):
    # Load configuration
    config_path = f"yana/train/config/{dataset_type}_feed_forward.yaml"
    config = load_yaml(config_path)
    config.trainer_cfg.output_path = f"./output/bulk/{dataset_type.upper()}"

    checkpoint_paths = [
        f"checkpoints/{dataset_type}.ckpt",
        f"checkpoints/{dataset_type}_30_pruning.ckpt"
    ]

    samples_output_dir = os.path.join(config.trainer_cfg.output_path, "test_samples")
    networks_output_dir = os.path.join(config.trainer_cfg.output_path, "networks")

    # Generate input sample data
    print(f"Exporting input data...")

    with SuppressOutput():
        _, _, data_module = initialize_experiment(config)
        os.makedirs(samples_output_dir, exist_ok=True)
        sample_batch_data = export_input_data(data_module, num_samples, samples_output_dir)

    print(f"Exporting networks...")

    progress_bar = tqdm(checkpoint_paths, f"{'':17}")
    for checkpoint_path in progress_bar:
        exp_name = os.path.splitext(os.path.basename(checkpoint_path))[0]
        progress_bar.set_description(f"{exp_name:17}")
        with SuppressOutput() as s:
            # Export NIR file
            config.trainer_cfg.checkpoint_path = checkpoint_path
            _, model, _ = initialize_experiment(config)

            experiment_output_dir = os.path.join(networks_output_dir, f"network_{exp_name}")
            network_output_file = os.path.join(experiment_output_dir, "network.nir")
            os.makedirs(experiment_output_dir, exist_ok=True)

            sample_data = next(iter(data_module.train_dataloader()))[0][0, 0:1, :]
            hardware_cfg = config.hardware_cfg
            quant_cfg = config.model_cfg.network_cfg["quant_cfg"]
            metadata = {"hardware_cfg": hardware_cfg, "quant_cfg": quant_cfg}
            export_nir(model.network, metadata, network_output_file, sample_data, dt=config.model_cfg.network_cfg["dt"], broadcast_params=False)

            # Generate network output data
            model.network.reset()
            model.eval()
            sample_batch_outputs = []

            for frame in sample_batch_data:
                sample_batch_output = model.network(frame)
                sample_batch_outputs.append(sample_batch_output.detach().numpy())

            sample_batch_outputs = np.stack(sample_batch_outputs)
            sample_outputs_dir = os.path.join(experiment_output_dir, "output_traces")
            os.makedirs(sample_outputs_dir, exist_ok=True)

            # Save samples to disk
            for sample in range(num_samples):
                file_output = os.path.join(sample_outputs_dir, f"neuron_state_trace_{sample}.npy")
                np.save(file_output, sample_batch_outputs[:, sample])


def _load_network(nir_path: str):
    nir_graph = nir.read(nir_path)
    metadata = nir_graph.metadata
    quant_options = options_from_config(metadata["quant_cfg"])
    accelerator_config = from_metadata(metadata["hardware_cfg"], quant_options.weight_format)
    network = Network(nir_graph, accelerator_config, quant_options, log_level=LogLevel.WARNING)
    return network, quant_options


def _simulate_and_write_traces(network, quant_options, input_events_list: list, output_dir: str, ref_traces_dir: str | None = None):
    """Simulate network for each sample, write neuron_state_trace_{idx}.txt to output_dir.

    If ref_traces_dir is given, compares simulation output against reference .npy files
    and returns (max_diffs, mses). Otherwise returns (None, None).
    """
    os.makedirs(output_dir, exist_ok=True)

    max_diffs = []
    mses = []

    for idx, (input_length, input_events) in enumerate(tqdm(input_events_list, "Output traces")):
        network.reset()
        output_neuron_states = network.simulate(input_events, input_length + 3, progressbar=False)

        if ref_traces_dir is not None:
            ref_file = os.path.join(ref_traces_dir, f"neuron_state_trace_{idx}.npy")
            ref_np = np.load(ref_file)
            sim_np = np.array([[state.to_float() for state in states_ts] for states_ts in output_neuron_states])
            diff = sim_np[3:] - ref_np
            max_diffs.append(np.max(np.abs(diff)))
            mses.append(np.mean(diff ** 2))

        trace_file = os.path.join(output_dir, f"neuron_state_trace_{idx}.txt")
        with open(trace_file, 'w') as f:
            for timestep, neuron_states_ts in enumerate(output_neuron_states[1:]):
                for neuron_idx, neuron_state in enumerate(neuron_states_ts):
                    f.write(f"{timestep} {neuron_idx} {int_to_binary_str(neuron_state.value, quant_options.state_format.wl)}\n")

    return (max_diffs, mses) if ref_traces_dir is not None else (None, None)


def deployment_export(dataset_type: str):
    # Load configuration
    config_path = f"yana/train/config/{dataset_type}_feed_forward.yaml"
    config = load_yaml(config_path)
    config.trainer_cfg.output_path = f"./output/bulk/{dataset_type.upper()}"

    accelerator_config = from_metadata(
        config.hardware_cfg,
        config.model_cfg.network_cfg["quant_cfg"]
    )

    samples_output_dir = os.path.join(config.trainer_cfg.output_path, "test_samples")
    networks_output_dir = os.path.join(config.trainer_cfg.output_path, "networks")

    # Get all directories in the networks_output_dir
    network_dirs = [
        os.path.join(networks_output_dir, d) for d in os.listdir(networks_output_dir)
        if os.path.isdir(os.path.join(networks_output_dir, d))
    ]
    # Find all .npy file names in samples_output_dir
    sample_files = [
        os.path.join(samples_output_dir, f) for f in os.listdir(samples_output_dir)
        if os.path.isfile(os.path.join(samples_output_dir, f)) and f.endswith(".npy")
    ]

    # Convert all samples and write to disk
    print(f"\nSaving input traces...")
    input_events_list = []
    for sample_file in sorted(sample_files):
        input_sample = np.load(sample_file)
        input_events = generate_input_events(input_sample)
        input_events_list.append((len(input_sample), input_events))

        input_trace_file = sample_file.replace(".npy", ".txt")
        with open(input_trace_file, 'w') as f:
            for timestep, pre_neuron_id in input_events:
                f.write(f"{timestep - 1} {pre_neuron_id:0{accelerator_config.neuron_id_bits}b}\n")

    # Iterate over all networks
    for network_dir in network_dirs:
        print(f"\nStarting deployment for network {os.path.basename(network_dir)}...")
        network, quant_options = _load_network(os.path.join(network_dir, "network.nir"))

        traces_dir = os.path.join(network_dir, "output_traces")
        max_diffs, mses = _simulate_and_write_traces(
            network, quant_options, input_events_list, traces_dir, ref_traces_dir=traces_dir
        )

        # Print average differences
        print(f"Average Maximum Difference = {np.mean(np.array(max_diffs))}")
        print(f"Average Mean Squared Error = {np.mean(np.array(mses))}\n")

        # Generate memory files
        network.generate_mem_files(network_dir, print_util=True)


def generate_output_traces(nir_path: str, samples_dir: str, output_dir: str):
    """Simulate network execution for all samples and write neuron state trace .txt files.

    Reads sample .npy files from samples_dir, simulates the network from nir_path,
    and writes neuron_state_trace_{idx}.txt files to output_dir.
    """
    network, quant_options = _load_network(nir_path)

    sample_files = sorted(
        f for f in os.listdir(samples_dir)
        if f.endswith(".npy") and os.path.isfile(os.path.join(samples_dir, f))
    )

    input_events_list = [
        (len(s := np.load(os.path.join(samples_dir, f))), generate_input_events(s))
        for f in sample_files
    ]

    _simulate_and_write_traces(network, quant_options, input_events_list, output_dir)


def export_sample_traces(dataset_type: str, num_samples: int, output_path: str, nir_path: str):
    """Export test sample input traces for a given dataset.

    Loads the dataset's data module, picks random test samples, converts them to
    input event trace .txt files, and writes sample_info.yaml to output_path.
    """
    config_path = f"yana/train/config/{dataset_type.lower()}_feed_forward.yaml"
    config = load_yaml(config_path)

    with SuppressOutput():
        _, _, data_module = initialize_experiment(config)
        export_input_data(data_module, num_samples, output_path)

    # Load accelerator config to format neuron IDs
    nir_graph = nir.read(nir_path)
    metadata = nir_graph.metadata
    quant_options = options_from_config(metadata["quant_cfg"])
    accelerator_config = from_metadata(metadata["hardware_cfg"], quant_options.weight_format)

    # Convert .npy samples to input trace .txt files
    for filename in sorted(os.listdir(output_path)):
        if not filename.endswith(".npy"):
            continue
        sample_file = os.path.join(output_path, filename)
        input_sample = np.load(sample_file)
        input_events = generate_input_events(input_sample)
        input_trace_file = sample_file.replace(".npy", ".txt")
        with open(input_trace_file, 'w') as f:
            for timestep, pre_neuron_id in input_events:
                f.write(f"{timestep - 1} {pre_neuron_id:0{accelerator_config.neuron_id_bits}b}\n")


def _parse_dataset(path: str) -> str:
    """Parse dataset name from a directory path. Returns uppercase dataset name."""
    lower = path.lower()
    for dataset in ["nmnist", "shd"]:
        if dataset in lower:
            return dataset.upper()
    raise ValueError(
        f"Could not determine dataset from path '{path}'. "
        "Path must contain 'nmnist' or 'shd'."
    )


def package_artifacts(input_dirs: list, output_path: str, num_samples: int = 10):
    """Package deployment output directories into a tar.gz archive.

    The archive structure mirrors the experiments layout:
        {DATASET}/networks/{net_name}/*.txt
        {DATASET}/test_samples/*.txt + sample_info.yaml

    A 'pruned_' prefix is added to the network name when 'pruning' appears
    anywhere in the directory path. One set of test samples is exported per
    unique dataset found across the provided directories.
    """
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)

    # Collect unique datasets and one representative nir_file.nir path per dataset
    datasets_nir: dict[str, str] = {}
    for version_dir in input_dirs:
        dataset = _parse_dataset(version_dir)
        if dataset not in datasets_nir:
            nir_path = os.path.join(version_dir.rstrip("/"), "nir_file.nir")
            datasets_nir[dataset] = nir_path

    with tempfile.TemporaryDirectory() as tmpdir, tarfile.open(output_path, "w:gz") as tar:
        # Export test samples for each unique dataset
        dataset_samples_dirs: dict[str, str] = {}
        for dataset, nir_path in datasets_nir.items():
            samples_dir = os.path.join(tmpdir, dataset, "test_samples")
            os.makedirs(samples_dir)
            print(f"\nExporting {num_samples} sample(s) for {dataset}...")
            export_sample_traces(dataset, num_samples, samples_dir, nir_path)
            dataset_samples_dirs[dataset] = samples_dir

            for filename in sorted(os.listdir(samples_dir)):
                if filename.endswith(".txt") or filename == "sample_info.yaml":
                    file_path = os.path.join(samples_dir, filename)
                    tar.add(file_path, arcname=f"{dataset}/test_samples/{filename}")

        # Pack network deployment files and generate output traces per network
        for version_dir in input_dirs:
            version_dir = version_dir.rstrip("/")
            deploy_dir = os.path.join(version_dir, "deploy")
            dataset = _parse_dataset(version_dir)
            net_name = os.path.basename(version_dir)
            arc_prefix = f"{dataset}/networks/{net_name}"

            txt_files = [
                f for f in os.listdir(deploy_dir)
                if os.path.isfile(os.path.join(deploy_dir, f)) and f.endswith(".txt")
            ]
            if not txt_files:
                print(f"Warning: no .txt files found in '{deploy_dir}', skipping.")
                continue

            for filename in sorted(txt_files):
                file_path = os.path.join(deploy_dir, filename)
                tar.add(file_path, arcname=f"{arc_prefix}/{filename}")

            print(f"Packed {len(txt_files)} file(s) from '{deploy_dir}' as '{arc_prefix}/'.")

            # Generate output traces for this network
            nir_path = os.path.join(version_dir, "nir_file.nir")
            traces_dir = os.path.join(tmpdir, dataset, net_name, "output_traces")
            print(f"Generating output traces for {net_name}...")
            generate_output_traces(nir_path, dataset_samples_dirs[dataset], traces_dir)

            for filename in sorted(os.listdir(traces_dir)):
                if filename.endswith(".txt"):
                    file_path = os.path.join(traces_dir, filename)
                    tar.add(file_path, arcname=f"{arc_prefix}/output_traces/{filename}")

    print(f"\nArchive created at '{output_path}'.")


def export_bulk_artifacts(archive_path: str):
    source_directory = "output/bulk/"

    def _include(path: str) -> bool:
        return path.endswith(".txt") or os.path.basename(path) == "sample_info.yaml"

    file_count = 0
    with tarfile.open(archive_path, "w:gz") as tar:
        for dirpath, dirnames, filenames in os.walk(source_directory):
            for filename in sorted(filenames):
                file_path = os.path.join(dirpath, filename)
                if _include(file_path):
                    arcname = os.path.relpath(file_path, source_directory)
                    tar.add(file_path, arcname=arcname)
                    file_count += 1

    print(f"Archive created at '{archive_path}' ({file_count} file(s) packed).")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Package deployment artifacts into a tar.gz archive, or run the legacy bulk export."
    )
    parser.add_argument(
        "-i", "--input-dirs",
        type=str,
        nargs="+",
        metavar="DIR",
        help="One or more version directories to package (e.g. output/nmnist/lightning_logs/version_0). The 'deploy/' subdirectory is used implicitly."
    )
    parser.add_argument(
        "-o", "--output",
        type=str,
        default="output/experiments.tar.gz",
        help="Path for the output tar.gz archive (default: output/experiments.tar.gz)."
    )
    parser.add_argument(
        "-n", "--num-samples",
        type=int,
        default=10,
        help="Number of test samples to export per dataset (default: 10)."
    )
    parser.add_argument(
        "--example",
        action="store_true",
        help="Run the legacy bulk export using the pretrained checkpoints."
    )
    args = parser.parse_args()

    if args.example:
        if args.input_dirs:
            parser.error("--input-dirs/-d cannot be used together with --example.")

        print("Exporting N-MNIST")
        training_export("nmnist", num_samples=10)
        deployment_export("nmnist")

        print("\n\nExporting SHD")
        training_export("shd", num_samples=10)
        deployment_export("shd")

        export_bulk_artifacts(archive_path=args.output)
    else:
        if not args.input_dirs:
            parser.error("--input-dirs/-d is required when not using --example.")

        package_artifacts(args.input_dirs, args.output, args.num_samples)
