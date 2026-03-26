from typing import NamedTuple

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


class FixedPoint:
    def __init__(self, value: int, quant_scheme: QuantScheme):
        self.value = value
        self.integer_bits = quant_scheme.integer_bits
        self.fractional_bits = quant_scheme.fractional_bits
        self.signed = quant_scheme.signed

    def to_bin(self) -> str:
        """Returns the raw binary representation of the fixed-point number, handling signed values."""
        total_bits = self.width()
        if self.signed and self.value < 0:
            # Apply two's complement for negative signed numbers
            binary = bin((self.value & ((1 << total_bits) - 1)) + (1 << total_bits))[2:].zfill(total_bits)
        else:
            binary = bin(self.value & ((1 << total_bits) - 1))[2:].zfill(total_bits)
        return binary

    def to_float(self) -> float:
        """Returns the float value of the fixed point number."""
        return self.value / (2 ** self.fractional_bits)

    def width(self) -> int:
        """Returns the total bit width of the fixed-point number."""
        return self.integer_bits + self.fractional_bits + (1 if self.signed else 0)

    def compressed(self, quant_scheme: QuantScheme) -> 'FixedPoint':
        """Returns a new FixedPoint object adjusted to match the given quantization scheme."""
        if quant_scheme.fractional_bits < self.fractional_bits:
            new_value = self.value >> (self.fractional_bits - quant_scheme.fractional_bits)
        else:
            new_value = self.value << (quant_scheme.fractional_bits - self.fractional_bits)

        return FixedPoint(new_value, quant_scheme)

    def __add__(self, other: 'FixedPoint') -> 'FixedPoint':
        """Return sum in widened fixed-point format."""
        return _fixed_point_add(self, other)

    def __mul__(self, other: 'FixedPoint') -> 'FixedPoint':
        """Return product in widened fixed-point format."""
        return _fixed_point_mul(self, other)

    def __gt__(self, other: 'FixedPoint') -> bool:
        """True if self > other after aligning fractional bits."""
        return _fixed_point_compare(self, other)

    def __lt__(self, other: 'FixedPoint') -> bool:
        """True if self < other after aligning fractional bits."""
        return not _fixed_point_compare(self, other)

    def __le__(self, other: 'FixedPoint') -> bool:
        return not self > other

    def __ge__(self, other: 'FixedPoint') -> bool:
        return not self < other

    def __iadd__(self, other: 'FixedPoint') -> 'FixedPoint':
        """In-place add; updates this object's value and format fields."""
        result = self + other
        self.value = result.value
        self.integer_bits = result.integer_bits
        self.fractional_bits = result.fractional_bits
        self.signed = result.signed
        return self

    def __imul__(self, other: 'FixedPoint') -> 'FixedPoint':
        """In-place multiply; updates this object's value and format fields."""
        result = self * other
        self.value = result.value
        self.integer_bits = result.integer_bits
        self.fractional_bits = result.fractional_bits
        self.signed = result.signed
        return self
    
    def __eq__(self, other: 'FixedPoint') -> bool:
        return self.value == other.value and self.integer_bits == other.integer_bits and self.fractional_bits == other.fractional_bits and self.signed == other.signed

    def __repr__(self):
        return f"FixedPoint(value={self.value}, float_value={self.to_float()}, integer_bits={self.integer_bits}, fractional_bits={self.fractional_bits}, signed={self.signed})"

    def __hash__(self):
        """Returns a hash value for the FixedPoint object."""
        return hash((self.value, self.integer_bits, self.fractional_bits, self.signed))

def max_value(quant_scheme: QuantScheme) -> FixedPoint:
    if quant_scheme.signed:
        value = (1 << (quant_scheme.integer_bits + quant_scheme.fractional_bits - 1)) - 1
    else:
        value = (1 << (quant_scheme.integer_bits + quant_scheme.fractional_bits)) - 1
    return FixedPoint(value, quant_scheme)

def min_value(quant_scheme: QuantScheme) -> FixedPoint:
    if quant_scheme.signed:
        value = -(1 << (quant_scheme.integer_bits + quant_scheme.fractional_bits - 1))
    else:
        value = 0
    return FixedPoint(value, quant_scheme)

def float_to_fixed_point(value: float, quant_scheme: QuantScheme) -> FixedPoint:
    """Converts a float to a fixed-point integer representation."""
    if quant_scheme.signed:
        clip_hi = (2.**(quant_scheme.integer_bits)) - (2.**-quant_scheme.fractional_bits)
        clip_lo = -(2.**(quant_scheme.integer_bits))
        if value > clip_hi:
            value = clip_hi
        if value < clip_lo:
            value = clip_lo
    else:
        clip_hi = (2.**quant_scheme.integer_bits) - (2.**-quant_scheme.fractional_bits)
        if value > clip_hi:
            value = clip_hi
        if value < 0:
            value = 0

    scale = 2.**quant_scheme.fractional_bits
    return FixedPoint(int(value * scale), quant_scheme)

def _fixed_point_add(fp1: FixedPoint, fp2: FixedPoint) -> FixedPoint:
    """Adds two fixed-point numbers, returning a full precision result."""
    val1 = fp1.value
    val2 = fp2.value

    # Align the fractional bits by shifting the smaller one
    if fp1.fractional_bits > fp2.fractional_bits:
        val2 <<= (fp1.fractional_bits - fp2.fractional_bits)
    elif fp2.fractional_bits > fp1.fractional_bits:
        val1 <<= (fp2.fractional_bits - fp1.fractional_bits)

    return FixedPoint(val1 + val2, QuantScheme(max(fp1.integer_bits, fp2.integer_bits) + 1, max(fp1.fractional_bits, fp2.fractional_bits), fp1.signed or fp2.signed))

def _fixed_point_mul(fp1: FixedPoint, fp2: FixedPoint) -> FixedPoint:
    """Multiplies two fixed-point numbers, returning a full precision result."""
    val1 = fp1.value
    val2 = fp2.value

    return FixedPoint(val1 * val2, QuantScheme(fp1.integer_bits + fp2.integer_bits, fp1.fractional_bits + fp2.fractional_bits, fp1.signed or fp2.signed))

def _fixed_point_compare(fp1: FixedPoint, fp2: FixedPoint) -> bool:
    """Compares two fixed-point numbers, taking into account their fractional bits."""
    val1 = fp1.value
    val2 = fp2.value

    # Align the fractional bits by shifting the smaller one
    if fp1.fractional_bits > fp2.fractional_bits:
        val2 <<= (fp1.fractional_bits - fp2.fractional_bits)
    elif fp2.fractional_bits > fp1.fractional_bits:
        val1 <<= (fp2.fractional_bits - fp1.fractional_bits)

    return val1 > val2

