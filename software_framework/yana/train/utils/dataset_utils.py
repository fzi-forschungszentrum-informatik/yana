import tonic
import torch
import pytorch_lightning as pl
import numpy as np
from dataclasses import dataclass
from typing import Callable, Optional

from tonic.collation import PadTensors

@dataclass
class TransformCfg:
    n_time_bins: int
    time_window: int
    spatial_factor: int
    merge_polarities: bool


@dataclass
class DatasetCfg:
    dataset: str
    path: str

    num_samples: int
    num_output_classes: int
    train_split: int
    random_seed: int

    transform_cfg: TransformCfg


@dataclass(frozen=True)
class ExpandDims:
    def __call__(self, target):
        return np.expand_dims(target, axis=-1)


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


def _split_trainset(trainset, train_split: float, random_seed: Optional[int] = None, num_samples: Optional[int] = None) -> tuple:
    generator_arg = {}
    if random_seed is not None:
        generator_arg["generator"] = torch.Generator().manual_seed(random_seed)

    if num_samples:
        trainset, _ = torch.utils.data.random_split(trainset, [num_samples, len(trainset) - num_samples], **generator_arg)

    trainset_size = int(len(trainset) * train_split)
    validset_size = len(trainset) - trainset_size
    trainset, validset = torch.utils.data.random_split(trainset, [trainset_size, validset_size], **generator_arg)

    return trainset, validset


def _construct_transform(cfg: TransformCfg, sensor_size: list):
    sensor_size_scaled = (
        sensor_size[0] // cfg.spatial_factor,
        1 if sensor_size[1] == 1 else sensor_size[1] // cfg.spatial_factor,
        1 if cfg.merge_polarities else 2,
    )

    transforms = []
    if cfg.spatial_factor != 1:
        transforms.append(tonic.transforms.Downsample(time_factor=1, spatial_factor=1 / cfg.spatial_factor))
    if cfg.merge_polarities:
        transforms.append(tonic.transforms.MergePolarities())

    if cfg.time_window and not cfg.n_time_bins:
        transforms.append(tonic.transforms.ToFrame(sensor_size=sensor_size_scaled, time_window=cfg.time_window))
    elif not cfg.time_window and cfg.n_time_bins:
        transforms.append(tonic.transforms.ToFrame(sensor_size=sensor_size_scaled, n_time_bins=cfg.n_time_bins))
    else:
        raise Exception("Set either cfg.time_window or cfg.n_time_bins")

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

    transform, target_transform, sensor_size_scaled = _construct_transform(cfg.transform_cfg, trainset.sensor_size)
    trainset.transform = transform
    trainset.target_transform = target_transform
    testset.transform = transform
    testset.target_transform = target_transform

    trainset, valset = _split_trainset(trainset, cfg.train_split, cfg.random_seed, cfg.num_samples)
    return trainset, testset, valset, sensor_size_scaled, len(testset.classes)


class LitDataModule(pl.LightningDataModule):
    def __init__(self, batch_size, trainset, validset, testset, shuffle: bool = True, num_workers: int = 4):
        super().__init__()
        self.batch_size = batch_size
        self.num_workers = num_workers
        self.shuffle = shuffle
        self.trainset = trainset
        self.validset = validset
        self.testset = testset

    def train_dataloader(self):
        return torch.utils.data.DataLoader(
            self.trainset,
            batch_size=self.batch_size,
            shuffle=self.shuffle, num_workers=self.num_workers,
            collate_fn=PadTensors(batch_first=True)
        )

    def val_dataloader(self):
        return torch.utils.data.DataLoader(
            self.validset,
            batch_size=self.batch_size,
            shuffle=False, num_workers=self.num_workers,
            collate_fn=PadTensors(batch_first=True)
        )

    def test_dataloader(self):
        return torch.utils.data.DataLoader(
            self.testset,
            batch_size=self.batch_size,
            shuffle=False, num_workers=self.num_workers,
            collate_fn=PadTensors(batch_first=True)
        )
