import argparse
import os
import random

import numpy as np
import pytorch_lightning as pl
import torch


from qtorch.quant import Quantizer
from qtorch import FixedPoint

from yana.train.utils.nir_utils import export_nir as _export_nir
from yana.train.config.config import *
from yana.train.model import Model
from yana.train.training import (
    initialize_experiment, do_training,
    do_test, export_samples,
    do_iterative_pruning
)
from yana.core.hardware_config import from_metadata


def quantize_weights(model: Model, quant_wl: int, quant_fl: int):
    weight_quantizer = Quantizer(FixedPoint(wl=quant_wl, fl=quant_fl), forward_rounding="nearest")

    quantized_weights = model.state_dict()
    for name, param in quantized_weights.items():
        if "weight" in name:
            quantized_weights[name] = weight_quantizer(param)
    model.load_state_dict(quantized_weights)


def export_nir(model: Model, cfg: Cfg, data_module: pl.LightningDataModule, output_path: str):
    sample_data = next(iter(data_module.train_dataloader()))[0][0, 0:1, :]
    output_file_nir = os.path.join(output_path, "nir_file.nir")

    hardware_cfg = cfg.hardware_cfg
    quant_cfg = cfg.model_cfg.network_cfg["quant_cfg"]
    metadata = {"hardware_cfg": hardware_cfg, "quant_cfg": quant_cfg}

    _export_nir(model.network, metadata, output_file_nir, sample_data, dt=cfg.model_cfg.network_cfg["dt"], broadcast_params=False)


def set_random_seed(seed: int):
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed(seed)
        torch.cuda.manual_seed_all(seed)
    pl.seed_everything(seed, workers=True)


if __name__ == "__main__":
    # Set random seed
    set_random_seed(42)

    # Parse configuration
    parser = argparse.ArgumentParser(description="Parse hierarchical command-line arguments.", formatter_class=argparse.MetavarTypeHelpFormatter)
    parser.add_argument("-c", "--config-path", type=str, default="yana/train/config/nmnist_feed_forward.yaml")

    # Create configurations
    add_dataclass_to_argparser(parser, Cfg)
    args = parser.parse_args()
    cfg = load_yaml(args.config_path, argparser_args_to_dict(args))
    accelerator_config = from_metadata(cfg.hardware_cfg, cfg.model_cfg.network_cfg["quant_cfg"])

    # Train network
    trainer, model, data_module = initialize_experiment(cfg)
    do_training(trainer, model, data_module)

    # Quantize network weights
    quantize_weights(model, accelerator_config.weight_quant_scheme.wl, accelerator_config.weight_quant_scheme.fl)

    # Test quantized network performance
    do_test(trainer, model, data_module)

    assert trainer.logger is not None and trainer.logger.log_dir is not None

    # Export evaluation samples and .nir file
    export_samples(1, model, data_module, trainer.logger.log_dir)
    export_nir(model, cfg, data_module, trainer.logger.log_dir)

    # Prune network
    if cfg.pruning_cfg.iterative_pruning and cfg.pruning_cfg.max_pruning > 0:
        pruning_log_dir = trainer.logger.log_dir + "_pruning"
        version = f"version_{trainer.logger.version}_pruning"

        do_iterative_pruning(model=model, cfg=cfg, version=version, datamodule=data_module, devices=cfg.trainer_cfg.device_num)

        # Export evaluation samples and .nir file
        export_samples(1, model, data_module, pruning_log_dir)
        export_nir(model, cfg, data_module, pruning_log_dir)

    print("Successfully finished the training and export of the SNN model.")
