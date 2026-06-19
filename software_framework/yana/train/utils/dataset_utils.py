import os
import random

import tonic
import torch
import pytorch_lightning as pl
import numpy as np
from typing import Callable, Optional

from yana.train.config import TransformCfg, DatasetCfg
from tonic.collation import PadTensors
from tonic.cached_dataset import DiskCachedDataset

from .augmented_transform import parse_augmented_transform
from .custom_transforms import PadSliceToBins, ExpandDims

def _get_dataset_by_name(dataset: str, save_to: str, transform: Optional[Callable], target_transform: Optional[Callable]):
    if dataset == "DVSGesture":
        trainset = tonic.datasets.DVSGesture(save_to=save_to, train=True, transform=transform, target_transform=target_transform)
        testset = tonic.datasets.DVSGesture(save_to=save_to, train=False, transform=transform, target_transform=target_transform)
    elif dataset == "NMNIST":
        trainset = tonic.datasets.NMNIST(save_to=save_to, train=True, transform=transform, target_transform=target_transform)
        testset = tonic.datasets.NMNIST(save_to=save_to, train=False, transform=transform, target_transform=target_transform)
    elif dataset == "SHD":
        trainset = tonic.datasets.SHD(save_to=save_to, train=True, transform=transform, target_transform=target_transform)
        testset = tonic.datasets.SHD(save_to=save_to, train=False, transform=transform, target_transform=target_transform)
    else:
        raise ValueError(f"Dataset {dataset} not (yet) supported.")

    return trainset, testset


def _split_trainset(trainset, train_split: float, num_samples: Optional[int] = None) -> tuple:
    if num_samples:
        trainset, _ = torch.utils.data.random_split(trainset, [num_samples, len(trainset) - num_samples])

    trainset_size = int(len(trainset) * train_split)
    validset_size = len(trainset) - trainset_size
    trainset, validset = torch.utils.data.random_split(trainset, [trainset_size, validset_size])

    return trainset, validset


def _construct_transform(cfg: TransformCfg, sensor_size: tuple, augmentation_enabled: bool):
    sensor_size_scaled = (
        sensor_size[0] // cfg.spatial_factor,
        1 if sensor_size[1] == 1 else sensor_size[1] // cfg.spatial_factor,
        1 if cfg.merge_polarities else 2,
    )

    transforms = []
    if cfg.merge_polarities:
        transforms.append(tonic.transforms.MergePolarities())

    if augmentation_enabled:
        transforms += parse_augmented_transform(cfg.augmentation_transforms, sensor_size)

    if cfg.spatial_factor != 1:
        transforms.append(tonic.transforms.Downsample(time_factor=1, spatial_factor=1 / cfg.spatial_factor))

    if cfg.time_window and not cfg.n_time_bins:
        transforms.append(tonic.transforms.ToFrame(sensor_size=sensor_size_scaled, time_window=cfg.time_window))
    elif not cfg.time_window and cfg.n_time_bins:
        transforms.append(tonic.transforms.ToFrame(sensor_size=sensor_size_scaled, n_time_bins=cfg.n_time_bins))
    elif cfg.time_window and cfg.n_time_bins:
        transforms.append(tonic.transforms.ToFrame(sensor_size=sensor_size_scaled, time_window=cfg.time_window))
        transforms.append(PadSliceToBins(cfg.n_time_bins, 1))
    else:
        raise Exception("set either cfg.time_window and/or cfg.n_time_bins")

    if sensor_size[1] == 1:
        # for 1D data like SHD, SMNIST ...
        transforms.append(ExpandDims())

    transforms.append(tonic.transforms.NumpyAsType(np.float32))
    transform = tonic.transforms.Compose(transforms)
    target_transform = None
    return transform, target_transform, sensor_size_scaled


def get_dataset(cfg: DatasetCfg):
    # construct dataset without transforms and apply them later
    trainset, testset = _get_dataset_by_name(cfg.dataset, cfg.path, None, None)
    sensor_size = trainset.sensor_size

    # Create data transformations
    transform, target_transform, sensor_size_scaled = _construct_transform(cfg.transform_cfg, sensor_size, augmentation_enabled=False)
    trainset.transform = transform
    trainset.target_transform = target_transform
    testset.transform = transform
    testset.target_transform = target_transform

    if cfg.transform_cfg.augmentation_enabled:
        augmented_transform, _, _ = _construct_transform(cfg.transform_cfg, sensor_size, augmentation_enabled=True)
        trainset.transform = augmented_transform

    if cfg.disk_cache:
        trainset = DiskCachedDataset(trainset, ".cache/datasets/train")
        testset = DiskCachedDataset(testset, ".cache/datasets/test")

    if cfg.train_split < 1.0:   # Use part of the trainset for validation
        trainset, valset = _split_trainset(trainset, cfg.train_split, cfg.num_samples)
    else:                       # Use testset for validation
        print("NOTE: using test set as validation set, ignoring num_samples flag")
        valset = testset

    return trainset, testset, valset, sensor_size_scaled, cfg.num_output_classes


class LitDataModule(pl.LightningDataModule):
    def __init__(self, batch_size, trainset, validset, testset, shuffle: bool = True, num_workers: int = 4, base_seed=42):
        super().__init__()
        self.batch_size = batch_size
        self.num_workers = num_workers
        self.shuffle = shuffle
        self.trainset = trainset
        self.validset = validset
        self.testset = testset

        self.base_seed = base_seed

    def setup_trainer(self, trainer):
        self.trainer = trainer

    def worker_init_fn(self, worker_id):
        current_epoch = getattr(self.trainer, 'current_epoch', 0) if self.trainer else 0

        worker_seed = (self.base_seed + current_epoch * 1000 + worker_id) % 2**32
        np.random.seed(worker_seed)
        torch.manual_seed(worker_seed)
        random.seed(worker_seed)

    def train_dataloader(self):
        return torch.utils.data.DataLoader(
            self.trainset, batch_size=self.batch_size,
            shuffle=self.shuffle, num_workers=self.num_workers,
            collate_fn=PadTensors(batch_first=True),
            worker_init_fn=self.worker_init_fn,
            persistent_workers=False
        )

    def val_dataloader(self):
        return torch.utils.data.DataLoader(
            self.validset, batch_size=self.batch_size,
            shuffle=False, num_workers=self.num_workers,
            collate_fn=PadTensors(batch_first=True),
        )

    def test_dataloader(self):
        return torch.utils.data.DataLoader(
            self.testset, batch_size=self.batch_size,
            shuffle=False, num_workers=self.num_workers,
            collate_fn=PadTensors(batch_first=True),
        )
