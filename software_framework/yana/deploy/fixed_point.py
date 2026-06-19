import math

from yana.core.config import QuantScheme

class FixedPoint:
    def __init__(self, value: int, quant_scheme: QuantScheme):
        self.value = value
        self.integer_bits = quant_scheme.integer_length
        self.fractional_bits = quant_scheme.fraction_length
        self.signed = quant_scheme.signed

    def to_float(self) -> float:
        """Returns the float value of the fixed point number."""
        return self.value / (2 ** self.fractional_bits)

    def width(self) -> int:
        """Returns the total bit width of the fixed-point number."""
        return self.integer_bits + self.fractional_bits + (1 if self.signed else 0)

    def resized(self, quant_scheme: QuantScheme) -> 'FixedPoint':
        """Returns a new FixedPoint object adjusted to match the given quantization scheme."""
        if quant_scheme.fraction_length == self.fractional_bits:
            return self

        if quant_scheme.fraction_length < self.fractional_bits:
            new_value = self.value >> (self.fractional_bits - quant_scheme.fraction_length)
        else:
            new_value = self.value << (quant_scheme.fraction_length - self.fractional_bits)

        return FixedPoint(new_value, quant_scheme)

    def resized_like(self, other: 'FixedPoint') -> 'FixedPoint':
        return self.resized(quant_scheme=QuantScheme.model_validate([other.integer_bits, other.fractional_bits, other.signed]))

    def __add__(self, other: 'FixedPoint') -> 'FixedPoint':
        """Overrides the addition operator for FixedPoint objects."""
        return _fixed_point_add(self, other)

    def __mul__(self, other: 'FixedPoint') -> 'FixedPoint':
        """Overrides the multiplication operator for FixedPoint objects."""
        return _fixed_point_mul(self, other)

    def __gt__(self, other: 'FixedPoint') -> bool:
        """Overrides the greater than operator for FixedPoint objects."""
        return _fixed_point_compare(self, other)

    def __lt__(self, other: 'FixedPoint') -> bool:
        """Overrides the less than operator for FixedPoint objects."""
        return not _fixed_point_compare(self, other)

    def __le__(self, other: 'FixedPoint') -> bool:
        """Overrides the less than or equal to operator for FixedPoint objects."""
        return not self > other

    def __ge__(self, other: 'FixedPoint') -> bool:
        """Overrides the greater than or equal to operator for FixedPoint objects."""
        return not self < other

    def __iadd__(self, other: 'FixedPoint') -> 'FixedPoint':
        """Implements the in-place addition operator for FixedPoint objects."""
        # Simple (and most common) case
        if self.fractional_bits == other.fractional_bits:
            self.value += other.value
        else:
            # Align the fractional bits by shifting the smaller one
            val1 = self.value
            val2 = other.value
            if self.fractional_bits > other.fractional_bits:
                val2 <<= (self.fractional_bits - other.fractional_bits)
            elif other.fractional_bits > self.fractional_bits:
                val1 <<= (other.fractional_bits - self.fractional_bits)

            self.value = val1 + val2
            self.integer_bits = max(self.integer_bits, other.integer_bits) + 1
            self.fractional_bits = max(self.fractional_bits, other.fractional_bits)
            self.signed = self.signed or other.signed

        return self

    def __imul__(self, other: 'FixedPoint') -> 'FixedPoint':
        """Implements the in-place multiplication operator for FixedPoint objects."""
        self.value *= other.value
        self.integer_bits += other.integer_bits
        self.fractional_bits += other.fractional_bits
        self.signed = self.signed or other.signed
        return self

    def __eq__(self, other: object) -> bool:
        """Overrides the equality operator for FixedPoint objects."""
        if not isinstance(other, FixedPoint):
            return NotImplemented
        return self.value == other.value and self.integer_bits == other.integer_bits and self.fractional_bits == other.fractional_bits and self.signed == other.signed

    def __repr__(self):
        return f"FixedPoint(value={self.value}, float_value={self.to_float()}, integer_length={self.integer_bits}, fraction_length={self.fractional_bits}, signed={self.signed})"

    def __hash__(self):
        """Returns a hash value for the FixedPoint object."""
        return hash((self.value, self.integer_bits, self.fractional_bits, self.signed))

def max_value(quant_scheme: QuantScheme) -> FixedPoint:
    """Calculate the maximum representable value for a given quantization scheme."""
    if quant_scheme.signed:
        value = (1 << (quant_scheme.integer_length + quant_scheme.fraction_length - 1)) - 1
    else:
        value = (1 << (quant_scheme.integer_length + quant_scheme.fraction_length)) - 1
    return FixedPoint(value, quant_scheme)

def min_value(quant_scheme: QuantScheme) -> FixedPoint:
    """Calculate the minimum representable value for a given quantization scheme."""
    if quant_scheme.signed:
        value = -(1 << (quant_scheme.integer_length + quant_scheme.fraction_length - 1))
    else:
        value = 0
    return FixedPoint(value, quant_scheme)

def float_to_fixed_point(value: float, quant_scheme: QuantScheme) -> FixedPoint:
    """Converts a float to a fixed-point integer representation.
        Rounding uses half-away-from-zero.
    """
    if quant_scheme.signed:
        max_value = (2.**(quant_scheme.integer_length)) - (2.**-quant_scheme.fraction_length)
        min_value = -(2.**(quant_scheme.integer_length))
        if value > max_value:
            value = max_value
        if value < min_value:
            value = min_value
    else:
        max_value = (2.**quant_scheme.integer_length) - (2.**-quant_scheme.fraction_length)
        if value > max_value:
            value = max_value
        if value < 0:
            value = 0

    scale = 2.**quant_scheme.fraction_length
    raw = value * scale
    rounded = int(math.copysign(math.floor(abs(raw) + 0.5), raw))
    return FixedPoint(rounded, quant_scheme)

def _fixed_point_add(fp1: FixedPoint, fp2: FixedPoint) -> FixedPoint:
    """Adds two fixed-point numbers, returning a full precision result."""
    val1 = fp1.value
    val2 = fp2.value

    # Align the fractional bits by shifting the smaller one
    if fp1.fractional_bits > fp2.fractional_bits:
        val2 <<= (fp1.fractional_bits - fp2.fractional_bits)
    elif fp2.fractional_bits > fp1.fractional_bits:
        val1 <<= (fp2.fractional_bits - fp1.fractional_bits)

    return FixedPoint(val1 + val2, QuantScheme(
        word_length=max(fp1.integer_bits, fp2.integer_bits) + 1,
        fraction_length=max(fp1.fractional_bits, fp2.fractional_bits),
        signed=fp1.signed or fp2.signed
    ))

def _fixed_point_mul(fp1: FixedPoint, fp2: FixedPoint) -> FixedPoint:
    """Multiplies two fixed-point numbers, returning a full precision result."""
    return FixedPoint(fp1.value * fp2.value, QuantScheme(
        word_length=fp1.integer_bits + fp2.integer_bits,
        fraction_length=fp1.fractional_bits + fp2.fractional_bits,
        signed=fp1.signed or fp2.signed
    ))

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


def int_to_binary_str(value: int, value_width: int) -> str:
    """
    Converts a signed integer value to its 2's complement binary representation.
    """
    if value >= 0:
        return f"{value:0{value_width}b}"
    else:
        return f"{(2**value_width + value):0{value_width}b}"
