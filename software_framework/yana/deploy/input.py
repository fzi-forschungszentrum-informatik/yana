
from typing import List, Tuple, Union
import numpy as np


def _load_sample(filepath: str) -> np.ndarray:
    return np.load(filepath)

def _format_sample(sample: np.ndarray) -> List[Tuple[int, int]]:
    input_events = []
    for ts, sample_ts in enumerate(sample):
        for neuron_id, value in enumerate(sample_ts.flatten()):
            for _ in range(int(value)):
                input_events.append([ts, neuron_id])
    return input_events

def generate_input_events(sample: Union[str, np.ndarray]) -> List[Tuple[int, int]]:
    if isinstance(sample, str):
        sample = _load_sample(sample)
    return _format_sample(sample)
