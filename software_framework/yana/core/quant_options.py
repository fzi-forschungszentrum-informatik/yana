from typing import Dict, List, NamedTuple

class QuantScheme(NamedTuple):
    integer_bits: int
    fractional_bits: int
    signed: bool

    @property
    def wl(self) -> int:
        return self.integer_bits + self.fractional_bits

    @property
    def fl(self) -> int:
        return self.fractional_bits

    def __repr__(self) -> str:
        return f"QuantScheme(integer_bits={self.integer_bits}, fractional_bits={self.fractional_bits}, signed={self.signed})"

    def __str__(self) -> str:
        return f"QuantScheme with {self.integer_bits} integer bits, {self.fractional_bits} fractional bits, signed={self.signed}"

class QuantOptions(NamedTuple):
    weight_format: QuantScheme
    state_format: QuantScheme
    tau_mem_inv_format: QuantScheme
    threshold_format: QuantScheme
    weight_sum_format: QuantScheme
    lut_ram_format: QuantScheme
    def __repr__(self) -> str:
        return (f"QuantOptions(weight_format={self.weight_format}, state_format={self.state_format}, "
                f"tau_mem_inv_format={self.tau_mem_inv_format}, threshold_format={self.threshold_format}, "
                f"weight_sum_format={self.weight_sum_format}, lut_ram_format={self.lut_ram_format})")

    def __str__(self) -> str:
        return (f"QuantOptions with weight_format={self.weight_format}, state_format={self.state_format}, "
                f"tau_mem_inv_format={self.tau_mem_inv_format}, threshold_format={self.threshold_format}, "
                f"weight_sum_format={self.weight_sum_format}, lut_ram_format={self.lut_ram_format}")

def scheme_from_config(scheme_config: List) -> QuantScheme:
    assert len(scheme_config) == 3, f"Scheme config format wrong: {scheme_config}"
    return QuantScheme(
        integer_bits = scheme_config[0] - scheme_config[1],
        fractional_bits = scheme_config[1],
        signed = scheme_config[2]
    )

def options_from_config(options_config: Dict) -> QuantOptions:
    return QuantOptions(
        weight_format=scheme_from_config(options_config["q_format_weights"]),
        state_format=scheme_from_config(options_config["q_format_state"]),
        tau_mem_inv_format=scheme_from_config(options_config["q_format_tau_inv_j"]),
        threshold_format=scheme_from_config(options_config["q_format_threshold"]),
        weight_sum_format=scheme_from_config(options_config["q_format_weight_sum"]),
        lut_ram_format=scheme_from_config(options_config["q_format_tau_inv_l"])
    )
