import argparse
import types as types_module
import typing
from pathlib import Path
from typing import Any, Dict, List, Optional, Union

import nir
import yaml
from pydantic import BaseModel
from pydantic.json_schema import SkipJsonSchema

from yana.core.config.yana_config import ConfigModel, _restore_none


# ─── Configuration models ─────────────────────────────────────────────────────


class TransformCfg(ConfigModel):
    n_time_bins: int
    time_window: int
    spatial_factor: int
    merge_polarities: bool
    augmentation_enabled: bool
    augmentation_transforms: Union[Dict[str, Any], List[Any]]


class DatasetCfg(ConfigModel):
    dataset: str
    path: str
    disk_cache: bool
    num_samples: int
    num_output_classes: int
    train_split: float
    transform_cfg: TransformCfg


class TrainerCfg(ConfigModel):
    output_path: str
    device_num: int
    batch_size: int
    num_epochs: int
    num_workers: int
    es_patience: int
    dataset_cfg: DatasetCfg
    checkpoint_path: Optional[str] = None
    random_seed: int


class OptimizerCfg(ConfigModel):
    optimizer: str
    loss: str
    lr: float
    lr_scheduler: Optional[str]
    lr_scheduler_cfg: Dict[str, Any]
    spikerate_target: float
    spikerate_loss_coefficient: float
    weight_decay: float
    loss_params: Optional[Dict[str, Any]] = None


class LayerCfg(ConfigModel):
    type: str
    params: Dict[str, Any] = {}


class NetworkCfg(ConfigModel):
    # Weight initialization
    weight_init_enable: bool
    weight_init_type: str
    weight_init_gain: float
    weight_init_gain_ramp: float
    # Layers configuration (either from nir or custom)
    nir_file: Union[str, SkipJsonSchema[nir.NIRGraph]] = ""
    layers: List[LayerCfg] = []
    # Time constant
    dt: float = 1.0


class ModelCfg(ConfigModel):
    network_type: str
    optimizer_cfg: OptimizerCfg
    network_cfg: NetworkCfg
    decoder_transforms: List[str]
    enable_tracking: bool


class PruningCfg(ConfigModel):
    pruned_layers: Optional[List[int]] = None
    scheduler_cfg: Dict[str, Any]


class Cfg(ConfigModel):
    trainer_cfg: TrainerCfg
    model_cfg: ModelCfg
    pruning_cfg: PruningCfg

    @classmethod
    def from_yaml(cls, path: str | Path, args: 'argparse.Namespace | dict' = {}) -> 'Cfg':
        """Load a Cfg from a YAML file, with optional CLI args or dict overrides."""
        with open(path) as f:
            data = yaml.safe_load(f)
        if isinstance(args, argparse.Namespace):
            args = _args_to_override_dict(args)
        _deep_update(data, args)
        data = _restore_none(data, "__none__")
        return cls.model_validate(data)

    @classmethod
    def add_args_to_parser(cls, parser: 'argparse.ArgumentParser') -> None:
        """Register all Cfg fields as dot-separated CLI arguments on *parser*."""
        _add_pydantic_to_argparser(parser, cls)


# ─── YAML loading helpers ─────────────────────────────────────────────────────


def _deep_update(original: dict, updates: dict) -> None:
    """Recursively update *original* in-place with values from *updates*."""
    for key, value in updates.items():
        if isinstance(value, dict) and key in original and isinstance(original[key], dict):
            _deep_update(original[key], value)
        else:
            original[key] = value


def print_config(cfg: Cfg) -> None:
    print(yaml.safe_dump(cfg.model_dump(), sort_keys=False))


# ─── CLI helpers ──────────────────────────────────────────────────────────────


def str2bool(v: str | bool) -> bool:
    if isinstance(v, bool):
        return v
    if v.lower() in ('yes', 'true', 't', 'y', '1'):
        return True
    elif v.lower() in ('no', 'false', 'f', 'n', '0'):
        return False
    else:
        raise argparse.ArgumentTypeError('Boolean value expected.')


def _unwrap_optional(annotation: Any) -> Any:
    """Return the inner type of ``Optional[X]`` / ``X | None``, or the annotation unchanged."""
    origin = typing.get_origin(annotation)
    if origin is Union:
        non_none = [a for a in typing.get_args(annotation) if a is not type(None)]
        if len(non_none) == 1:
            return non_none[0]
    if hasattr(types_module, 'UnionType') and isinstance(annotation, types_module.UnionType):
        non_none = [a for a in typing.get_args(annotation) if a is not type(None)]
        if len(non_none) == 1:
            return non_none[0]
    return annotation


def _scalar_argparse_type(annotation: Any):
    """
    Return an argparse type callable for *annotation*, or ``None`` if the
    annotation is a nested :class:`BaseModel` that should be recursed into.
    Dict/List/complex types fall back to ``str``.
    """
    resolved = _unwrap_optional(annotation)
    if isinstance(resolved, type) and issubclass(resolved, BaseModel):
        return None  # signal: recurse into nested model
    if resolved is bool:
        return str2bool
    if resolved is int:
        return int
    if resolved is float:
        return float
    if resolved is str:
        return str
    return str  # Dict, List, and other complex types → plain string


def _add_pydantic_to_argparser(
    parser: argparse.ArgumentParser,
    model_cls: type[BaseModel],
    base_name: str = "",
) -> None:
    prefix = base_name + "." if base_name else ""
    for field_name, field_info in model_cls.model_fields.items():
        full_name = prefix + field_name
        arg_type = _scalar_argparse_type(field_info.annotation)
        if arg_type is None:
            inner_cls = _unwrap_optional(field_info.annotation)
            _add_pydantic_to_argparser(parser, inner_cls, full_name)
        else:
            parser.add_argument(
                f"--{full_name}",
                type=arg_type,
                default=None,
                help=field_info.description,
            )


def _args_to_override_dict(args: argparse.Namespace) -> dict:
    result: dict = {}
    for key, value in vars(args).items():
        if '.' not in key or value is None:
            continue
        parts = key.split('.')
        d = result
        for part in parts[:-1]:
            d = d.setdefault(part, {})
        d[parts[-1]] = value
    return result
