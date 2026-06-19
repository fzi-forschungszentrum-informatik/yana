from tonic import transforms
from .custom_transforms import DropEventChunk, Roll, Rotate, Scale, RandomCutout


def parse_augmented_transform(transform_config: dict, sensor_size):
    transform_list = []

    for transform_string, transform_params in transform_config.items():
        match transform_string:
            # Event transformations
            case "denoise":
                transform_list.append(transforms.Denoise(filter_time=transform_params["filter_time"]))
            case "drop_event":
                transform_list.append(transforms.DropEvent(p=transform_params["probability"]))
            case "drop_event_chunk":
                transform_list.append(DropEventChunk(p=0.3, max_drop_size=transform_params["max_drop_chunk"]))
            case "uniform_noise":
                transform_list.append(transforms.UniformNoise(sensor_size=sensor_size, n=(0, transform_params["num_noise_events"])))

            # Spatial transformations
            case "spatial_jitter":
                transform_list.append(transforms.SpatialJitter(
                    sensor_size=sensor_size,
                    var_x=transform_params["variance"],
                    var_y=transform_params["variance"],
                    clip_outliers=True
                ))

            # Temporal transformations
            case "time_skew":
                transform_list.append(transforms.TimeSkew(
                    coefficient=(1/transform_params["skew_value"],
                    transform_params["skew_value"]), offset=0
                ))
            case "time_jitter":
                transform_list.append(transforms.TimeJitter(
                    std=transform_params["std_deviation"],
                    clip_negative=False,
                    sort_timestamps=True
                ))

            # Geometric transformations
            case "cutout":
                transform_list.append(RandomCutout(
                    p=transform_params["p"], sensor_size=sensor_size,
                    cutout_size_range=transform_params["cutout_size_range"],
                    allowed_area=(transform_params["cutout_area_x"], sensor_size[1]),
                ))
            case "roll":
                transform_list.append(Roll(sensor_size=sensor_size, p=transform_params["p"], max_roll=transform_params["max_roll"]))
            case "rotate":
                transform_list.append(Rotate(sensor_size=sensor_size, p=transform_params["p"], max_angle=transform_params["max_angle"]))
            case "scale":
                transform_list.append(Scale(sensor_size=sensor_size, p=transform_params["p"], max_scale=transform_params["max_scale"]))
            case _:
                raise ValueError(f"Unknown transformation type: {transform_string}")

    return transform_list
