import torch
from typing import Union
from . import utils

## How to add new hooks:
# Define a function with arguments (module, args, kwargs, output, layer_name) and implement the desired behavior.
# See https://docs.pytorch.org/docs/stable/generated/torch.nn.Module.html#torch.nn.Module.register_forward_hook for
# more details on hook signatures and behavior. We use with_kwargs=True for more flexibility.
# The layer_name argument is passed via a closure to identify which layer's output is being tracked. To use the
# hook, simply add the method of a tracker instance to the list of functions in register_forward_state_hooks in the
# BaseNetwork class.

## Future improvements:
# - Add a heatmap plot for all neurons in a layer

class Tracker:
    def __init__(self, path = None):
        self.tracking = {
            "accumulated_spikes": {},
            "accumulated_states": {},
        }
        self.path = path

    def accumulate_spikes(self, module: torch.nn.Module, args, kwargs, output, layer_name: str):
        # Handle tuple outputs from stateful layers
        if isinstance(output, tuple):
            output, states = output
            # For LI neurons, output and states are the same, so we can skip accumulation
            if output == states:
                return

        if isinstance(output, torch.Tensor):
            output = output.detach().clone()
        else:
            return
        
        utils.accumulated(self.tracking["accumulated_spikes"], layer_name, output)


    def accumulate_states(self, module: torch.nn.Module, args, kwargs, output, layer_name: str):
        # Handle tuple outputs from stateful layers
        if isinstance(output, tuple):
            output, states = output
        
        if hasattr(states, "v"):
            states = states.v
        
        if isinstance(states, torch.Tensor):                                                                           
            states = states.detach().clone()                                                                             
        else:                                                                                                            
            # Unsupported state type (e.g. dict from FX GraphModule)                                                     
            return
      

        utils.accumulated(self.tracking["accumulated_states"], layer_name, states)


    def save(self, path=None):
        import os
        import json
        path = path or self.path
        os.makedirs(path, exist_ok=True)
        tracking_path = os.path.join(path, "tracking.json")
        serializable = {
            key: {layer: value.tolist() for layer, value in layers.items()}
            for key, layers in self.tracking.items()
        }
        with open(tracking_path, "w") as f:
            json.dump(serializable, f, indent=4)


    def plot(self, layer_name, neuron_id: Union[int, list, None] = None, tracking_variable: str = None, show = True, save=False, path: str =None):
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        path = path or self.path

        for key, value in self.tracking.items():
            # If tracking_variable is specified only plot that tracked variable
            if tracking_variable and key != tracking_variable:
                continue

            key_title = key.replace("_", " ").title()

            value_keys = value.keys() if not layer_name else [layer_name]
            for lname in value_keys:
                layer_value = value.get(lname)
                if layer_value is None:
                    raise ValueError(f"No tracking data found for layer '{lname}' and variable '{key}'. Available layers: {list(self.tracking[key].keys())}")
                if neuron_id is None:
                    layer_value = layer_value.reshape(layer_value.shape[0], -1).sum(dim=1) if len(layer_value.shape) > 1 else layer_value
                elif isinstance(neuron_id, list):
                    # layer_value.shape is (time_steps, num_neurons)
                    for id in neuron_id:
                        layer_value = layer_value[:, id]
                elif isinstance(neuron_id, int):
                    layer_value = layer_value[:, neuron_id]

                if len(layer_value.shape) != 1:
                    raise ValueError(f"Expected 1D tensor for plotting, but got shape {layer_value.shape} for key '{key}' in layer '{lname}' with neuron_id '{neuron_id}'. Please check the dimensions of the accumulated data or specify a valid neuron_id.")

                plt.figure(figsize=(10, 4))
                plt.plot(layer_value.detach().cpu().numpy())
                plt.title(f"{key_title} - Layer: {lname}, Neuron ID: {neuron_id}")
                plt.xlabel("Time Steps")
                plt.ylabel(key_title)
                if save:
                    import os
                    os.makedirs(path, exist_ok=True)
                    neuron_id_str = "_".join(map(str, neuron_id)) if isinstance(neuron_id, list) else str(neuron_id) if neuron_id is not None else "sum_all_neurons"
                    plt.savefig(os.path.join(path, f"plot_{lname}_{neuron_id_str}_{key}.png"))
                if show:
                    plt.show()

    
    def reset(self):
        for key in self.tracking:
            self.tracking[key] = {}


    def __getitem__(self, key):
        return self.tracking[key]


    def __contains__(self, key):
        return key in self.tracking


    def __iter__(self):
        return iter(self.tracking)


    def __len__(self):
        return len(self.tracking)


    def get(self, key, default=None):
        return self.tracking.get(key, default)


    def keys(self):
        return self.tracking.keys()


    def values(self):
        return self.tracking.values()


    def items(self):
        return self.tracking.items()
