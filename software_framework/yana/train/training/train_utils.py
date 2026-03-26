import os
from typing import List, Optional
from dataclasses import asdict
import yaml

import torch
from torch.utils.data import random_split
from pytorch_lightning.callbacks import Callback, ModelCheckpoint, EarlyStopping
from pytorch_lightning.loggers import TensorBoardLogger
import pytorch_lightning as pl
import numpy as np

from yana.train.config import Cfg
from yana.train.utils.dataset_utils import LitDataModule, get_dataset
from yana.train.model import Model


def initialize_experiment(cfg: Cfg, limit_batches: float = 1.0, study_name: str = "lightning_logs", version: Optional[int] = None, additional_callbacks: List[Callback] = []):
    trainer_cfg = cfg.trainer_cfg

    trainset, testset, valset, sensor_size, num_classes = get_dataset(trainer_cfg.dataset_cfg)
    data_module = LitDataModule(trainer_cfg.batch_size, trainset, valset, testset, shuffle=True, num_workers=4)

    print(f"\nLoaded Dataset: {trainer_cfg.dataset_cfg.dataset}")
    print(f"  size:        training [{len(trainset)}], validation [{len(valset)}], test [{len(testset)}]")
    print(f"  used:        training [{int(limit_batches*len(trainset))}], validation [{int(limit_batches*len(valset))}], test [{int(limit_batches*len(testset))}]")
    print(f"  num_classes: {num_classes}")
    print(f"  sensor_size: {sensor_size}")

    model = Model(cfg.model_cfg, sensor_size, num_classes)
    print("\nLoaded Model:", model)

    torch.set_float32_matmul_precision("high")

    callbacks = [
        ModelCheckpoint(save_top_k=1, save_last=True, monitor="val/loss", filename=trainer_cfg.dataset_cfg.dataset + "-{epoch:02d}-{val_acc:.2f}"),
        EarlyStopping(monitor="val/loss", mode="min", patience=trainer_cfg.es_patience),
    ]

    accelerator_type = "cpu" if trainer_cfg.device_num < 0 else "gpu"
    print(f"\nUsing device type: {accelerator_type}\n")

    trainer_args = {
        "default_root_dir": trainer_cfg.output_path,
        "max_epochs": trainer_cfg.num_epochs,
        "callbacks": callbacks + additional_callbacks,
        "accelerator": accelerator_type,
        "devices": 1 if trainer_cfg.device_num < 0 else [trainer_cfg.device_num],
        "limit_train_batches": limit_batches,
        "limit_val_batches": limit_batches,
        "limit_test_batches": limit_batches,
    }

    logger = TensorBoardLogger(save_dir=trainer_cfg.output_path, name=study_name, version=version, default_hp_metric=False)
    trainer = pl.Trainer(logger=logger, **trainer_args)

    print("Trainer output path:", trainer.logger.log_dir)

    if not os.path.exists(trainer.logger.log_dir):
        os.makedirs(trainer.logger.log_dir)

    with open(os.path.join(trainer.logger.log_dir, "parsed_config.yaml"), "w") as f:
        yaml.safe_dump(asdict(cfg), f, sort_keys=False)

    if trainer_cfg.checkpoint_path is not None:
        print(f"Loading checkpoint: {trainer_cfg.checkpoint_path}")
        map_location = "cpu" if trainer_cfg.device_num < 0 else f"cuda:{trainer_cfg.device_num}"
        model_dict = torch.load(trainer_cfg.checkpoint_path, map_location=map_location, weights_only=False)
        try:
            model.load_state_dict(model_dict["state_dict"])
        except KeyError:  # this specific case only arises if loading from the pruned models
            model.load_state_dict(model_dict)

    return trainer, model, data_module


def do_training(trainer: pl.Trainer, model: Model, data_module: pl.LightningDataModule):
    trainer.fit(model, datamodule=data_module, ckpt_path=None)

def do_test(trainer: pl.Trainer, model: Model, data_module: pl.LightningDataModule):
    test_result = trainer.test(model, datamodule=data_module)

    with open(os.path.join(trainer.logger.log_dir, "test_result_post_training.txt"), mode="a") as f:
        f.write(str(test_result) + "\n")


def export_samples(num_samples: int, model: Model, data_module: pl.LightningDataModule, output_path: str):
    test_set = data_module.test_dataloader().dataset

    # Ensure num_samples is not greater than the total number of samples
    total_samples = len(test_set)
    if num_samples > total_samples:
        num_samples = total_samples

    # Choose random samples from train dataset
    samples, _ = random_split(test_set, [num_samples, total_samples - num_samples])
    sample_loader = torch.utils.data.DataLoader(samples, batch_size=num_samples, shuffle=False)
    sample_batch_data, _ = next(iter(sample_loader))
    sample_batch_data = sample_batch_data.permute([1, 0, 2, 3, 4])

    model.network.reset()
    model.eval()
    sample_batch_outputs = []
    for _, frame in enumerate(sample_batch_data):  # Iterate over each timestep
        sample_batch_output = model.network(frame)
        sample_batch_outputs.append(sample_batch_output.detach().numpy())

    sample_batch_outputs = np.stack(sample_batch_outputs)

    file_data = os.path.join(output_path, "sample_data.npy")
    file_output = os.path.join(output_path, "sample_output.npy")
    np.save(file_data, sample_batch_data.cpu().detach().numpy())
    np.save(file_output, sample_batch_outputs)
