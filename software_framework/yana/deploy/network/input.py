from typing import List, Union
import numpy as np

def _load_sample(filepath: str) -> np.ndarray:
    return np.load(filepath)

def _format_sample(sample: np.ndarray) -> List:
    input_events = []
    for ts, sample_ts in enumerate(sample):
        for neuron_id, value in enumerate(sample_ts.flatten()):
            for _ in range(int(value)):
                input_events.append([ts+1, neuron_id])
    return input_events

def generate_input_events(np_sample: Union[str, np.ndarray]) -> List:
    if isinstance(np_sample, str):
        np_sample = _load_sample(np_sample)
    return _format_sample(np_sample)
