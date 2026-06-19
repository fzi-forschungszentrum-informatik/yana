import argparse
import os

from yana.train.utils.nir_utils import export_nir
from yana.train.utils import quantize_weights
from yana.train.config import Cfg
from yana.train.training import (
    initialize_experiment, export_samples, do_pruning
)
from yana.core.config import AcceleratorConfig


def export_model(model, data_module, acc_cfg, cfg, samples_log_dir, nir_log_dir):
    # Export evaluation samples and .nir file
    export_samples(1, model, data_module, samples_log_dir)
    # Export NIR file
    sample_data = next(iter(data_module.train_dataloader()))[0][0, 0:1, :]
    output_file_nir = os.path.join(nir_log_dir, "nir_file.nir")

    metadata = {"accelerator_config": acc_cfg.to_dict()}
    export_nir(model.network, metadata, output_file_nir, sample_data, dt=cfg.model_cfg.network_cfg.dt)


if __name__ == "__main__":
    # Parse configuration
    parser = argparse.ArgumentParser(description="Prune a trained SNN checkpoint.", formatter_class=argparse.MetavarTypeHelpFormatter)
    parser.add_argument("-a", "--accelerator-config-path", type=str, default="yana/core/config/default/accelerator.yaml")
    parser.add_argument("-e", "--export", action="store_true")
    parser.add_argument("-q", "--quantize", action="store_true")
    parser.add_argument("-C", "--checkpoint-dir", type=str, required=True, help="Training run directory (e.g. .../lightning_logs/version_x) to prune.")

    Cfg.add_args_to_parser(parser)
    args = parser.parse_args()

    assert os.path.isdir(args.checkpoint_dir), f"Checkpoint directory not found: {args.checkpoint_dir}"
    checkpoint_dir = os.path.normpath(args.checkpoint_dir)

    # Load config from the training run being pruned
    config_path = os.path.join(checkpoint_dir, "parsed_config.yaml")
    assert os.path.isfile(config_path), f"Config not found: {config_path}"

    cfg = Cfg.from_yaml(config_path, args)
    acc_cfg = AcceleratorConfig.from_yaml(args.accelerator_config_path)
    assert acc_cfg.core_config_hidden is not None, "Hidden core config is required."
    quant_config = acc_cfg.core_config_hidden.quant_config

    # Use the first available checkpoint of the training run
    checkpoints_dir = os.path.join(checkpoint_dir, "checkpoints")
    checkpoint_files = []
    for root, dirs, files in os.walk(checkpoints_dir):
        for file in files:
            checkpoint_files.append(os.path.join(root, file))
    assert checkpoint_files, f"No checkpoint found in {checkpoints_dir}"
    cfg.trainer_cfg.checkpoint_path = checkpoint_files[0]

    # Load model from checkpoint.
    _, model, data_module = initialize_experiment(cfg, acc_cfg, enable_logs=False)

    # Derive the pruning output location from the checkpoint directory.
    study_dir = os.path.dirname(checkpoint_dir)            # .../lightning_logs
    save_dir = os.path.dirname(study_dir)                  # .../ (parent of study)
    study_name = os.path.basename(study_dir)               # lightning_logs
    pruning_version = f"{os.path.basename(checkpoint_dir)}_pruning"  # version_x_pruning

    pruning_log_dir = do_pruning(
        model=model,
        cfg=cfg,
        version=pruning_version,
        datamodule=data_module,
        devices=cfg.trainer_cfg.device_num,
        save_dir=save_dir,
        study_name=study_name,
    )

    # Quantize network weights
    if args.quantize:
        print("\nQuantizing model weights...")
        quantize_weights(model, quant_config.format_weights.word_length, quant_config.format_weights.fraction_length)

    if args.export:
        # Export final pruned network
        export_model(model, data_module, acc_cfg, cfg, pruning_log_dir, pruning_log_dir)

    print("Successfully finished pruning of SNN model.")
