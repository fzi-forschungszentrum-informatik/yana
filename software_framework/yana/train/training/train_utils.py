import os
from typing import List
from dataclasses import asdict
import yaml

import torch
from torch.utils.data import random_split
from pytorch_lightning.callbacks import Callback, ModelCheckpoint, ModelSummary, EarlyStopping, LearningRateMonitor
from pytorch_lightning.loggers import TensorBoardLogger
import pytorch_lightning as pl
import numpy as np

from yana.train.config import Cfg
from yana.train.utils.dataset_utils import LitDataModule, get_dataset
from yana.train.model import Model
from yana.core.config import AcceleratorConfig

def set_random_seed(seed: int):
    pl.seed_everything(seed, workers=True)


def initialize_experiment(
    cfg: Cfg, acc_cfg: AcceleratorConfig, limit_batches: float = 1.0, study_name: str = "lightning_logs",
    enable_logs: bool = True, version: int | str | None = None, additional_callbacks: List[Callback] = []
):
    # Set random seed
    set_random_seed(cfg.trainer_cfg.random_seed)

    trainer_cfg = cfg.trainer_cfg

    trainset, testset, valset, sensor_size, num_classes = get_dataset(trainer_cfg.dataset_cfg)
    data_module = LitDataModule(
        trainer_cfg.batch_size, trainset, valset, testset, 
        shuffle=True, num_workers=cfg.trainer_cfg.num_workers, 
        base_seed=cfg.trainer_cfg.random_seed
    )

    print(f"\nLoaded Dataset: {trainer_cfg.dataset_cfg.dataset}")
    print(f"  size:        training [{len(trainset)}], validation [{len(valset)}], test [{len(testset)}]")
    print(f"  used:        training [{int(limit_batches*len(trainset))}], validation [{int(limit_batches*len(valset))}], test [{int(limit_batches*len(testset))}]")
    print(f"  num_classes: {num_classes}")
    print(f"  sensor_size: {sensor_size}")
    print(f"  num_workers: {cfg.trainer_cfg.num_workers}")

    model = Model(cfg.model_cfg, acc_cfg, sensor_size, num_classes)
    print("\nLoaded Model:", model)

    torch.set_float32_matmul_precision("high")

    callbacks = [
        ModelCheckpoint(
            save_top_k=1, mode="max", save_last=False, monitor="val/acc",
            filename="epoch={epoch}-val_acc={val/acc:.2f}",
            auto_insert_metric_name=False   # This makes metric names with '/' possible
        ),
        ModelSummary(max_depth=3),
        EarlyStopping(monitor="val/acc", mode="max", patience=trainer_cfg.es_patience),
        LearningRateMonitor(logging_interval="step")
    ]

    accelerator_type = "cpu" if trainer_cfg.device_num < 0 else "gpu"
    print(f"\nUsing device type: {accelerator_type}\n")

    trainer_args = {
        "default_root_dir": trainer_cfg.output_path,
        "max_epochs": trainer_cfg.num_epochs,
        "callbacks": callbacks + additional_callbacks,
        "accelerator": accelerator_type,
        "devices": 1 if trainer_cfg.device_num < 0 else [trainer_cfg.device_num],
        "log_every_n_steps": 5,
        "gradient_clip_val": 1.0,
        "limit_train_batches": limit_batches,
        "limit_val_batches": limit_batches,
        "limit_test_batches": limit_batches,
        "deterministic": True
    }

    logger = (
        TensorBoardLogger(save_dir=trainer_cfg.output_path, name=study_name, version=version, default_hp_metric=False)
        if enable_logs else False
    )
    trainer = pl.Trainer(logger=logger, **trainer_args)
    data_module.setup_trainer(trainer)

    if enable_logs:
        assert logger and trainer.logger is not None and trainer.logger.log_dir is not None, "No logger configured"
        print("Trainer output path:", trainer.logger.log_dir)

        if not os.path.exists(trainer.logger.log_dir):
            os.makedirs(trainer.logger.log_dir)

        with open(os.path.join(trainer.logger.log_dir, "parsed_config.yaml"), "w") as f:
            yaml.safe_dump(cfg.to_dict(), f, sort_keys=False)
    else:
        print("Trainer logging disabled.")

    if trainer_cfg.checkpoint_path is not None:
        print(f"Loading checkpoint: {trainer_cfg.checkpoint_path}")
        map_location = "cpu" if trainer_cfg.device_num < 0 else f"cuda:{trainer_cfg.device_num}"
        model_dict = torch.load(trainer_cfg.checkpoint_path, map_location=map_location, weights_only=False)
        state_dict = model_dict["state_dict"] if "state_dict" in model_dict else model_dict

        # Register extra "weight_mask" buffers for pruned checkpoints, placing
        # them on the same device as the module's weight so they move together
        # with the rest of the model under .to()/.cuda()/.cpu().
        for mask_key in [k for k in state_dict if k.endswith("weight_mask")]:
            module_path, _, buffer_name = mask_key.rpartition(".")
            submodule = model.get_submodule(module_path)
            if not hasattr(submodule, buffer_name):
                submodule.register_buffer(buffer_name, state_dict[mask_key].to(submodule.weight.device))

        model.load_state_dict(state_dict)

    return trainer, model, data_module


def do_training(trainer: pl.Trainer, model: Model, data_module: pl.LightningDataModule):
    trainer.fit(model, datamodule=data_module, ckpt_path=None)

def do_test(trainer: pl.Trainer, model: Model, data_module: pl.LightningDataModule):
    test_result = trainer.test(model, datamodule=data_module)

    if trainer.logger:
        assert trainer.logger.log_dir is not None, "No logger configured"
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
    sample_batch_data = sample_batch_data.permute(1, 0, *range(2, sample_batch_data.ndim))

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
