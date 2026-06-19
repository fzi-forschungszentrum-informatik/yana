from enum import Enum
import math
import sys
from typing import Any, Dict, Literal, Optional, Tuple, Union
from typing_extensions import Self
from pathlib import Path

import yaml
from pydantic import BaseModel, ConfigDict, field_validator, model_validator


def _ceiled_width(value: Union[int, float]) -> int:
    return math.ceil(math.log2(value))


def _replace_none(obj: Any, placeholder: Any) -> Any:
    """Recursively replace None values in a dict/list structure with *placeholder*."""
    if obj is None:
        return placeholder
    if isinstance(obj, dict):
        return {k: _replace_none(v, placeholder) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_replace_none(v, placeholder) for v in obj]
    return obj


def _restore_none(obj: Any, placeholder: Any) -> Any:
    """Inverse of _replace_none: replace *placeholder* back to None."""
    if type(obj) is type(placeholder) and obj == placeholder:
        return None
    if isinstance(obj, dict):
        return {k: _restore_none(v, placeholder) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_restore_none(v, placeholder) for v in obj]
    return obj


class ConfigModel(BaseModel):
    model_config = ConfigDict(arbitrary_types_allowed=True)

    @model_validator(mode='before')
    @classmethod
    def _load_from_path(cls, data: Any) -> Any:
        '''
        Convert sub-configurations into dictionaries.
        '''
        if isinstance(data, (str, Path)):
            with open(data) as f:
                return yaml.safe_load(f)
        return data

    @classmethod
    def from_yaml(cls, path: str | Path) -> Self:
        '''
        Support for loading .yaml files into configurations.
        '''
        with open(path) as f:
            return cls.model_validate(yaml.safe_load(f))

    def to_yaml(self, path: str | Path) -> None:
        '''
        Serialize the configuration to a .yaml file.
        '''
        with open(path, 'w') as f:
            yaml.dump(self.model_dump(mode='json'), f)

    @classmethod
    def from_dict(cls, data: dict, none_placeholder: Any = "__none__") -> Self:
        '''
        Load configuration from a dictionary.
        If *none_placeholder* is given, values equal to it are converted back to None
        before validation (inverse of ``to_dict(none_placeholder=...)``)
        '''
        if none_placeholder is not None:
            data = _restore_none(data, none_placeholder)
        return cls.model_validate(data)

    def to_dict(self, none_placeholder: Any = "__none__") -> dict:
        '''
        Serialize the configuration to a dictionary.
        If *none_placeholder* is given, None values are replaced with it so that
        the result can be stored in formats that do not support None (e.g. h5py).
        Pass the same value to ``from_dict`` to round-trip correctly.
        '''
        d = self.model_dump(mode='json')
        if none_placeholder is not None:
            d = _replace_none(d, none_placeholder)
        return d

    def print_all(self, recursive: bool = False, _indent: int = 0) -> None:
        prefix = "  " * _indent
        # Pydantic fields
        for name, field_info in type(self).model_fields.items():
            value = getattr(self, name)
            type_name = field_info.annotation.__name__ if hasattr(field_info.annotation, "__name__") else str(field_info.annotation)    # type: ignore
            if recursive and isinstance(value, ConfigModel):
                print(f"{prefix}{name}: {type_name} =")
                value.print_all(recursive=True, _indent=_indent + 1)
            else:
                print(f"{prefix}{name}: {type_name} = {value}")
        # Properties
        for klass in type(self).__mro__:
            for attr, obj in vars(klass).items():
                if not isinstance(obj, property) or attr.startswith("_"):
                    continue
                annotations = getattr(obj.fget, "__annotations__", {})
                ret = annotations.get("return", None)
                type_name = ret.__name__ if hasattr(ret, "__name__") else str(ret) if ret else "property"   # type: ignore
                try:
                    value = getattr(self, attr)
                    print(f"{prefix}{attr}: {type_name} = {value}")
                except Exception as e:
                    print(f"{prefix}{attr}: {type_name} = <error: {e}>")


class NeuronConfig(BaseModel):
    emit_spikes: bool
    leak_enabled: bool
    tau_mem_inv: float
    threshold: float = sys.float_info.max # Default no spikes
    reset_value: float = 0.0
    leak_lut_len: int

    @property
    def leak_lut_addr_width(self) -> int:
        return _ceiled_width(self.leak_lut_len) if self.leak_lut_len > 0 else 0

class QuantScheme(BaseModel):
    word_length: int
    fraction_length: int
    signed: bool

    @model_validator(mode='before')
    @classmethod
    def _from_list(cls, data: Any) -> Any:
        if isinstance(data, (list, tuple)):
            return {
                "word_length": data[0],
                "fraction_length": data[1],
                "signed": data[2]
            }
        return data

    @property
    def integer_length(self) -> int:
        return self.word_length - self.fraction_length

class QuantConfig(ConfigModel):
    format_weights: QuantScheme
    format_weight_sum: QuantScheme
    format_state: QuantScheme
    format_threshold: QuantScheme
    format_tau_inv_l: QuantScheme
    format_tau_inv_j: QuantScheme

class CoreConfig(ConfigModel):
    class Type(Enum):
        INPUT   = 0
        HIDDEN  = 1
        OUTPUT  = 2

    type: Type
    neuron_config: NeuronConfig
    quant_config: QuantConfig

    @field_validator('type', mode='before')
    @classmethod
    def _coerce_type(cls, v: Any) -> "CoreConfig.Type":
        if isinstance(v, str):
            return cls.Type[v.upper()]
        if isinstance(v, int):
            return cls.Type(v)
        return v

class PlatformConfig(ConfigModel):
    target: Literal["k26"]
    uram_width: int
    input_data_buffer_width: int

class AcceleratorConfig(ConfigModel):
    num_cores_x: int
    num_cores_y: int
    neurons_per_core: int
    routes_per_core: int
    weights_per_core: int

    timestep_width: int
    weight_sum_width: int
    instruction_width: int
    param_width: int
    mem_init_targets: Dict[str, int]

    core_configs: Dict[int, CoreConfig]
    platform_config: PlatformConfig

    @model_validator(mode='after')
    def _validate(self) -> "AcceleratorConfig":
        # Weight width must be the same for all configurations
        unique_weight_widths = set([core_config.quant_config.format_weights.word_length for core_config in self.core_configs.values()])
        assert len(unique_weight_widths) == 1, f"All cores must have identical weight widths. Got {unique_weight_widths}"
        # Weight sum width must be the same for all configurations
        unique_weight_sum_widths = set([core_config.quant_config.format_weight_sum.word_length for core_config in self.core_configs.values()])
        assert len(unique_weight_sum_widths) == 1, f"All cores must have identical weight sum widths. Got {unique_weight_sum_widths}"
        # Spike threshold width must be the same for all configurations
        unique_threshold_widths = set([core_config.quant_config.format_threshold.word_length for core_config in self.core_configs.values()])
        assert len(unique_threshold_widths) == 1, f"All cores must have identical weight sum widths. Got {unique_threshold_widths}"
        # Leak LUT width must be the same for all configurations
        unique_leak_lut_widths = set([core_config.quant_config.format_tau_inv_l.word_length for core_config in self.core_configs.values()])
        assert len(unique_leak_lut_widths) == 1, f"All cores must have identical weight sum widths. Got {unique_leak_lut_widths}"
        # TODO: add more validation
        # ...

        return self

    #
    # Helper methods
    #

    def core_id_to_xy(self, core_id: int) -> Tuple[int, int]:
        assert core_id < self.num_cores, f"Core ID {core_id} exceeds number of cores {self.num_cores}"
        x = core_id % self.num_cores_x
        y = core_id // self.num_cores_x
        return x, y

    #
    # Filter core configs
    #

    @property
    def core_config_input(self) -> CoreConfig:
        core_config_input = None
        for core_config in self.core_configs.values():
            if core_config.type == CoreConfig.Type.INPUT:
                assert core_config_input is None, "Only a single input core is allowed"
                core_config_input = core_config
        assert core_config_input is not None, "Input core is required."
        return core_config_input

    @property
    def core_config_hidden(self) -> Optional[CoreConfig]:
        core_config_hidden = None
        for core_config in self.core_configs.values():
            if core_config.type == CoreConfig.Type.HIDDEN:
                if core_config_hidden is not None:
                    assert core_config_hidden == core_config, "Currently, all hidden cores need to have the same configuration"
                else:
                    core_config_hidden = core_config
        return core_config_hidden

    @property
    def core_config_output(self) -> CoreConfig:
        core_config_output = None
        for core_config in self.core_configs.values():
            if core_config.type == CoreConfig.Type.OUTPUT:
                assert core_config_output is None, "Only a single output core is allowed"
                core_config_output = core_config
        assert core_config_output is not None, "Output core is required."
        return core_config_output

    #
    # General configuration
    #

    # Top

    @property
    def input_data_width(self) -> int:
        return self.timestep_width + self.neuron_id_width

    @property
    def input_control_width(self) -> int:
        return self.instruction_width + self.param_width

    # Mesh

    @property
    def num_cores(self) -> int:
        return self.num_cores_x * self.num_cores_y

    @property
    def core_id_x_width(self) -> int:
        return _ceiled_width(self.num_cores_x)

    @property
    def core_id_y_width(self) -> int:
        return _ceiled_width(self.num_cores_y)

    @property
    def packet_dx_width(self) -> int:
        return self.core_id_x_width + 2

    @property
    def packet_dy_width(self) -> int:
        return self.core_id_y_width + 1

    @property
    def packet_addr_width(self) -> int:
        return self.packet_dx_width + self.packet_dy_width

    @property
    def packet_data_width_x(self) -> int:
        # +1 for ctrl_flag
        return max(32, self.route_width + 1)

    @property
    def packet_data_width_y(self) -> int:
        return self.packet_data_width_x - self.packet_dx_width

    # Core

    @property
    def neuron_id_width(self) -> int:
        return _ceiled_width(self.neurons_per_core)

    @property
    def weight_id_width(self) -> int:
        return _ceiled_width(self.weights_per_core)

    @property
    def event_width(self) -> int:
        return self.weight_id_width + self.neuron_id_width

    @property
    def route_width(self) -> int:
        return self.packet_addr_width + self.event_width

    @property
    def input_width(self) -> int:
        return self.neuron_id_width + self.timestep_width

    #
    # Weight RAM configuration
    #

    # NOTE: for now, as identical word lengths for all cores are enforced, this is fine.
    #       If this constraint is relaxed on the hardware side, this should be reworked.
    @property
    def weights_per_line(self):
        assert self.core_configs[0], "Index 0 need to be populated"
        return self.platform_config.uram_width // self.core_configs[0].quant_config.format_weights.word_length

    @property
    def weight_ram_addr_width(self) -> int:
        return _ceiled_width(self.weights_per_core / self.weights_per_line)

    @property
    def weight_ram_data_width(self) -> int:
        return self.platform_config.uram_width

    @property
    def weight_sum_ram_addr_width(self) -> int:
        return self.neuron_id_width

    @property
    def weight_sum_ram_data_width(self) -> int:
        return self.weight_sum_width + 1

    #
    # Routes RAM configuration
    #

    @property
    def routes_ram_data_width(self) -> int:
        return self.platform_config.uram_width

    @property
    def routes_ram_entries_per_line(self) -> int:
        return self.routes_ram_data_width // self.route_width

    @property
    def routes_ram_addr_width(self) -> int:
        return _ceiled_width(self.routes_per_core / self.routes_ram_entries_per_line)

    #
    # Mapping RAM configuration
    #

    @property
    def mapping_ram_last_idx_width(self) -> int:
        return _ceiled_width(self.routes_ram_entries_per_line)

    @property
    def mapping_ram_data_width(self) -> int:
        return 2 * self.routes_ram_addr_width + self.mapping_ram_last_idx_width

    #
    # Initialization packet configuration
    #

    @property
    def init_burst_width(self) -> int:
        '''
        Maximum width required by any possible initialization burst.
        Any burst (for a given initialization target) writes one entire
        word in the target RAM and consists of:
        [ (packet addr), packet data ].
        For scalar values like spike threshold and inverse tau, there is no address.
        '''
        def max_lut_addr_width():
            return max(
                core_config.neuron_config.leak_lut_addr_width for core_config in self.core_configs.values()
            )

        assert self.core_config_hidden is not None, "Hidden core config required."
        return max(
            self.weight_ram_addr_width      + self.platform_config.uram_width,                                   # synapse weights
            self.neuron_id_width            + self.mapping_ram_data_width,                                       # axon mapping
            self.routes_ram_addr_width      + self.platform_config.uram_width,                                   # axon routes
                                              self.core_config_hidden.quant_config.format_threshold.word_length, # spike threshold
                                              self.core_config_hidden.quant_config.format_tau_inv_j.word_length, # inverse membrane tau
            max_lut_addr_width()            + self.core_config_hidden.quant_config.format_tau_inv_l.word_length, # leak LUT
        )

    @property
    def init_burst_num_events(self) -> int:
        return math.ceil(self.init_burst_width / self.init_event_payload_width)

    @property
    def init_event_width(self) -> int:
        '''
        Width of a single initialization event once it reaches a core.
        +1 for control flag, which can be freely used for initialization.
        '''
        return self.event_width + 1

    @property
    def init_event_target_width(self) -> int:
        return _ceiled_width(len(self.mem_init_targets))

    @property
    def init_event_payload_width(self) -> int:
        '''
        Actual usable data within a single initialization event.
        '''
        return self.init_event_width - self.init_event_target_width

    @property
    def init_packet_width(self) -> int:
        '''
        Width of an initialization packet, fully assembled including
        NoC routing information.
        '''
        return self.packet_addr_width + self.init_event_width
