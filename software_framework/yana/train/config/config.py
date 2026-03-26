from copy import deepcopy
from dataclasses import dataclass, fields, asdict, is_dataclass
from typing import Dict
import yaml

from yana.train.model.model import ModelCfg
from yana.train.utils.dataset_utils import DatasetCfg


@dataclass
class TrainerCfg:
    output_path: str
    device_num : int
    batch_size: int
    num_epochs: int
    es_patience: int
    dataset_cfg: DatasetCfg
    checkpoint_path: str

@dataclass
class PruningCfg:
    iterative_pruning: bool
    pruning_per_step: float
    max_pruning: float
    frequency: int
    method: str
    mode: str

@dataclass
class Cfg:
    trainer_cfg: TrainerCfg
    model_cfg: ModelCfg
    hardware_cfg: Dict
    pruning_cfg: PruningCfg


def dataclass_from_dict(cls, data: dict):
    """
    Recursively convert a dictionary to a dataclass, handling both nested dataclasses and dicts.
    """
    fieldtypes = {f.name: f.type for f in fields(cls)}  # Get the fields and their types for the dataclass

    return cls(
        **{
            f: (
                dataclass_from_dict(fieldtypes[f], data[f])  # Recursively handle nested dataclasses
                if isinstance(data[f], dict) and hasattr(fieldtypes[f], "__dataclass_fields__")
                else data[f]  # Leave dicts or other values unchanged
            )
            for f in data
        }
    )


def deep_update_dict(original, updates):
    """
    If the value is a dict, recursively update it. Otherwise, just update the value
    """
    for key, value in updates.items():
        if isinstance(value, dict) and key in original:
            deep_update_dict(original[key], value)
        else:
            original[key] = value


def deep_apply_includes(cfg_dict, copy=None):
    """
    iterate over copy of dict dict
    """
    if not copy:
        copy = deepcopy(cfg_dict)

    for key, value in copy.items():
        if isinstance(value, dict) and key in copy:
            deep_apply_includes(cfg_dict[key], copy[key])
        else:
            if ".yaml" in key:
                include_dict = None
                if value:  # allow null
                    try:
                        with open(value, "r") as f:
                            include_dict = yaml.safe_load(f)
                    except:
                        raise Exception(f"couldn't open include yaml {key}: '{value}'")

                cfg_dict[key.replace(".yaml", "")] = include_dict
                del cfg_dict[key]


def add_dataclass_to_argparser(parser, cls, base_name=""):
    if base_name:
        base_name += "."

    for field in fields(cls):
        full_name = base_name + field.name

        if is_dataclass(field.type):
            add_dataclass_to_argparser(parser, field.type, full_name)
        elif getattr(field.type, "__origin__", None) == dict:
            parser.add_argument("--" + full_name, type=str)
        else:
            # print(full_name, field.type, isinstance(field.type, dict))
            parser.add_argument("--" + full_name, type=field.type)


def argparser_args_to_dict(args):
    """
    Converts a flat dictionary with dot-separated keys into a hierarchical dictionary.
    For example: {'config.host': 'localhost'} becomes {'config': {'host': 'localhost'}}
    useful for commandline arguments
    """

    # filter out main args
    flat_dict = {k: v for k, v in vars(args).items() if "." in k}  

    result = {}
    for key, value in flat_dict.items():
        if value is None:
            continue  # Skip None values
        keys = key.split(".")
        d = result
        for k in keys[:-1]:
            d = d.setdefault(k, {})
        d[keys[-1]] = value
    return result


def load_yaml(config_file_path, overide_dict={}) -> Cfg:
    with open(config_file_path, "r") as f:
        cfg_dict = yaml.safe_load(f)

    # apply overrides
    deep_update_dict(cfg_dict, overide_dict)

    # apply yaml includes
    deep_apply_includes(cfg_dict)

    cfg = dataclass_from_dict(Cfg, cfg_dict)

    return cfg

def print_config(cfg : Cfg):
    print(yaml.safe_dump(asdict(cfg), sort_keys=False))
