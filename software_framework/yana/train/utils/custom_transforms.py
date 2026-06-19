from dataclasses import dataclass
import math
from typing import Tuple
import numpy as np

def cutout(events, sensor_size, cutout_size_range, allowed_area):
    assert allowed_area[0] <= sensor_size[0] and allowed_area[1] <= sensor_size[1]
    assert cutout_size_range[0] <= allowed_area[0] and cutout_size_range[1] <= allowed_area[1]
    assert "x" and "y" in events.dtype.names

    # Create random cutout shape
    cutout_size = []
    cutout_size.append(int(cutout_size_range[0] + np.random.rand() * (cutout_size_range[1] - cutout_size_range[0])))
    cutout_size.append(int(cutout_size_range[0] + np.random.rand() * (cutout_size_range[1] - cutout_size_range[0])))

    # Calculate minimum and maximum for the center indices
    x_center_ind_min = int((sensor_size[0] - allowed_area[0]) / 2 + cutout_size[0] / 2)
    x_center_ind_max = int((sensor_size[0] + allowed_area[0]) / 2 - cutout_size[0] / 2)
    y_center_ind_min = int((sensor_size[1] - allowed_area[1]) / 2 + cutout_size[1] / 2)
    y_center_ind_max = int((sensor_size[1] + allowed_area[1]) / 2 - cutout_size[1] / 2)
    # Calculate the center indices
    x_center_ind = int(x_center_ind_min + np.random.rand() * (x_center_ind_max - x_center_ind_min))
    y_center_ind = int(y_center_ind_min + np.random.rand() * (y_center_ind_max - y_center_ind_min))
    # Create the mask
    event_mask = (
        (events["x"] < int(x_center_ind - cutout_size[0] / 2))
        + (events["x"] >= int(x_center_ind + cutout_size[0] / 2))
        + (events["y"] < int(y_center_ind - cutout_size[1] / 2))
        + (events["y"] >= int(y_center_ind + cutout_size[1] / 2))
    )

    events = events[event_mask, ...]
    return events

def rotate(events, sensor_size, center_point, allowed_angle):
    assert center_point[0] <= sensor_size[0] and center_point[1] <= sensor_size[1]
    assert "x" and "y" in events.dtype.names

    angle = (np.random.rand() - 0.5) * 2 * allowed_angle
    angle_rad = math.radians(angle)

    events = events.copy()

    temp_x = events["x"].copy()
    events["x"] = (
        math.cos(angle_rad) * events["x"] -
        math.sin(angle_rad) * events["y"] -
        math.cos(angle_rad) * center_point[0] +
        math.sin(angle_rad) * center_point[1] +
        center_point[0]
    )
    events["y"] = (
        math.sin(angle_rad) * temp_x +
        math.cos(angle_rad) * events["y"] -
        math.sin(angle_rad) * center_point[0] -
        math.cos(angle_rad) * center_point[1] +
        center_point[1]
    )

    # Cut off any events that are outside the sensor frame
    event_mask = (
        (events["x"] < sensor_size[0])
        * (events["x"] >= 0)
        * (events["y"] < sensor_size[1])
        * (events["y"] >= 0)
    )

    events = events[event_mask, ...]
    return events

def translate(events, sensor_size, max_amount):
    assert max_amount[0] <= sensor_size[0] and max_amount[1] <= sensor_size[1]
    assert "x" and "y" in events.dtype.names

    trans_x = np.random.rand() * max_amount[0]
    trans_y = np.random.rand() * max_amount[1]
    events = events.copy()

    events["x"] = events["x"] + trans_x
    events["y"] = events["y"] + trans_y

    # Cut off any events that are outside the sensor frame
    event_mask = (
        (events["x"] < sensor_size[0])
        * (events["x"] >= 0)
        * (events["y"] < sensor_size[1])
        * (events["y"] >= 0)
    )

    events = events[event_mask, ...]
    return events


@dataclass(frozen=True)
class RandomCutout:
    """Cuts out a randomly sized part of the picture in a random location.

    Parameters:
        sensor_size: a 3-tuple of x,y,p for sensor_size
        cutout_size_range: a tuple of min,max of the size span of the randomized cutout
        allowed_area: a tuple of x,y for the size of the centered area in which cutouts are allowed
    """

    p: float
    sensor_size: Tuple[int, int, int]
    cutout_size_range: Tuple[int, int]
    allowed_area: Tuple[int, int]

    def __call__(self, events):
        if np.random.rand() > self.p:
            return events
        return cutout(
            events=events,
            sensor_size=self.sensor_size,
            cutout_size_range=self.cutout_size_range,
            allowed_area=self.allowed_area
        )


# Replaced by 'Rotate' transform

@dataclass(frozen=True)
class RandomRotate:
    """Randomly rotates the picture by a maximum of <allowed_angle> degrees
       (can be positive or negative).

    Parameters:
        sensor_size: a 3-tuple of x,y,p for sensor_size
        center_point: a tuple of x,y of the center point of the rotation
        allowed_angle: an int of the maximum absolute value of the random rotation
    """

    p: float
    sensor_size: Tuple[int, int, int]
    center_point: Tuple[int, int]
    allowed_angle: int

    def __call__(self, events):
        if np.random.rand() > self.p:
            return events
        return rotate(
            events=events,
            sensor_size=self.sensor_size,
            center_point=self.center_point,
            allowed_angle=self.allowed_angle
        )


# Replaced by 'Roll' transform

@dataclass(frozen=True)
class RandomTranslate:
    """Randomly translates the picture by a maximum of <max_amount> in
       the x and y direction (can be positive or negative).

    Parameters:
        sensor_size: a 3-tuple of x,y,p for sensor_size
        max_amount: an 2-tuple of x,y maximum absolute value of the
                    random translation
    """

    p: float
    sensor_size: Tuple[int, int, int]
    max_amount: Tuple[int, int]

    def __call__(self, events):
        if np.random.rand() > self.p:
            return events
        return translate(
            events=events,
            sensor_size=self.sensor_size,
            max_amount=self.max_amount
        )


@dataclass(frozen=True)
class ExpandDims:
    def __call__(self, target):
        return np.expand_dims(target, axis=-1)


@dataclass(frozen=True)
class PadSliceToBins:
    pad_time_bins : int = 1
    mode : int = 1              # 1: cut/append at end -1: cut/prepend at front
    def __call__(self, events):
        l = len(events)
        if l > self.pad_time_bins:
            if self.mode == 1:
                return events[:self.pad_time_bins]
            elif self.mode == -1: 
                return events[-self.pad_time_bins:]
        elif l < self.pad_time_bins:
            if self.mode == 1:
                return np.pad(events, ((0,self.pad_time_bins-l),(0,0),(0,0),(0,0)), 'constant', constant_values=0)
            elif self.mode == -1: 
                return np.pad(events, ((self.pad_time_bins-l,0),(0,0),(0,0),(0,0)), 'constant', constant_values=0)
        else:
            return events


class DropEventChunk:
    """
    This is directly copied from
    https://github.com/Efficient-Scalable-Machine-Learning/event-ssm/blob/main/event_ssm/transform.py

    Randomly drop a chunk of events
    """
    def __init__(self, p, max_drop_size):
        self.drop_prob = p
        self.max_drop_size = max_drop_size

    def __call__(self, events):
        max_drop_events = self.max_drop_size * len(events)
        if np.random.rand() < self.drop_prob:
            drop_size = np.random.randint(1, max_drop_events)
            start = np.random.randint(0, len(events) - drop_size)
            events = np.delete(events, slice(start, start + drop_size), axis=0)
        return events


class Roll:
    """
    This is directly copied from
    https://github.com/Efficient-Scalable-Machine-Learning/event-ssm/blob/main/event_ssm/transform.py

    Roll event x, y coordinates by a random amount

    Parameters:
        max_roll (int): maximum number of pixels to roll by
    """
    def __init__(self, sensor_size, p, max_roll):
        self.sensor_size = sensor_size
        self.max_roll = max_roll
        self.p = p

    def __call__(self, events):
        if np.random.rand() > self.p:
            return events
        # roll x, y coordinates by a random amount
        roll_x = np.random.randint(-self.max_roll, self.max_roll)
        roll_y = np.random.randint(-self.max_roll, self.max_roll)
        events['x'] += roll_x
        events['y'] += roll_y
        # remove events who got shifted out of the sensor size
        mask = (events['x'] >= 0) & (events['x'] < self.sensor_size[0]) & (events['y'] >= 0) & (events['y'] < self.sensor_size[1])
        events = events[mask]
        return events


class Rotate:
    """
    This is directly copied from
    https://github.com/Efficient-Scalable-Machine-Learning/event-ssm/blob/main/event_ssm/transform.py

    Rotate event x, y coordinates by a random angle
    """
    def __init__(self, sensor_size, p, max_angle):
        self.p = p
        self.sensor_size = sensor_size
        self.max_angle = 2 * np.pi * max_angle / 360

    def __call__(self, events):
        if np.random.rand() > self.p:
            return events
        # rotate x, y coordinates by a random angle
        angle = np.random.uniform(-self.max_angle, self.max_angle)
        x = events['x'] - self.sensor_size[0] / 2
        y = events['y'] - self.sensor_size[1] / 2
        x_new = x * np.cos(angle) - y * np.sin(angle)
        y_new = x * np.sin(angle) + y * np.cos(angle)
        events['x'] = (x_new + self.sensor_size[0] / 2).astype(np.int32)
        events['y'] = (y_new + self.sensor_size[1] / 2).astype(np.int32)
        # clip to original range
        events['x'] = np.clip(events['x'], 0, self.sensor_size[0] - 1)
        events['y'] = np.clip(events['y'], 0, self.sensor_size[1] - 1)
        return events


class Scale:
    """
    This is directly copied from
    https://github.com/Efficient-Scalable-Machine-Learning/event-ssm/blob/main/event_ssm/transform.py

    Scale event x, y coordinates by a random factor
    """
    def __init__(self, sensor_size, p, max_scale):
        assert max_scale >= 1
        self.p = p
        self.sensor_size = sensor_size
        self.max_scale = max_scale

    def __call__(self, events):
        if np.random.rand() > self.p:
            return events
        # scale x, y coordinates by a random factor
        scale = np.random.uniform(1/self.max_scale, self.max_scale)
        x = events['x'] - self.sensor_size[0] / 2
        y = events['y'] - self.sensor_size[1] / 2
        x_new = x * scale
        y_new = y * scale
        events['x'] = (x_new + self.sensor_size[0] / 2).astype(np.int32)
        events['y'] = (y_new + self.sensor_size[1] / 2).astype(np.int32)
        # remove events who got shifted out of the sensor size
        mask = (events['x'] >= 0) & (events['x'] < self.sensor_size[0]) & (events['y'] >= 0) & (events['y'] < self.sensor_size[1])
        events = events[mask]
        return events
