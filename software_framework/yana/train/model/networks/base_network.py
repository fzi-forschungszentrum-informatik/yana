import inspect
import pytorch_lightning as pl
from typing import Callable, List, Union

import nir
import torch

from yana.train.model.networks import hooks
from yana.train.config import NetworkCfg
from yana.train.utils import import_from_nir, TraceInterface
from yana.core.config import AcceleratorConfig


class BaseNetwork(pl.LightningModule, TraceInterface):
    def __init__(
        self,
        input_shape: List[int],
        output_features: int,
        enable_tracking: bool,
        network_cfg: NetworkCfg,
        accelerator_cfg: AcceleratorConfig
    ):
        super().__init__()
        self.input_shape = input_shape
        self.output_features = output_features
        self.dt = network_cfg.dt
        assert accelerator_cfg.core_config_hidden is not None, "Hidden core config required."
        self.quant_config = accelerator_cfg.core_config_hidden.quant_config

        # Accumulated spikes
        self.enable_tracking = enable_tracking
        if self.enable_tracking:
            self.tracker = hooks.Tracker()

        # Init Layers
        self.layers: torch.nn.Module = None
        if network_cfg.nir_file != "": # overwrites self.layers
            self.from_nir(network_cfg.nir_file)
        self.states = None

    def _compute_output_shape(self, input_shape: List[int] = None) -> torch.Size:
        if input_shape is None:
            input_shape = self.input_shape
        with torch.no_grad():
            dummy_input = torch.zeros([1, input_shape[-1], *input_shape[:-1]])
            output = self.layers(dummy_input)
            if isinstance(output, tuple):
                output = output[0]
            return output.shape

    def forward(self, x):
        if self.tracing:
            return self.forward_nir_export(x)
        outputs, self.states = self.layers(x, self.states)
        # Get last output
        if isinstance(outputs, list):
            outputs = outputs[-1]
        return outputs

    def _forward_for_tracing(self, x):
        """Forward pass used during NIR export tracing. Override in subclasses for
        network-specific adjustments (e.g. disabling return_hidden)."""
        outputs, self.states = self.layers(x, self.states)
        if isinstance(outputs, list):
            outputs = outputs[-1]
        return outputs

    def forward_nir_export(self, x):
        """Wraps _forward_for_tracing with hook-pausing to prevent FX TraceErrors."""
        saved_hooks = {
            mod: dict(mod._forward_hooks)
            for mod in self.modules()
            if mod._forward_hooks
        }
        for mod in saved_hooks:
            mod._forward_hooks.clear()
        try:
            return self._forward_for_tracing(x)
        finally:
            for mod, hook_dict in saved_hooks.items():
                mod._forward_hooks.update(hook_dict)

    def reset(self):
        if self.enable_tracking:
            self.tracker.reset()
        # Reset stateful layers to prevent stale tensor references from
        # leaking across batches (causes "backward through freed graph" errors).
        if self.layers is None:
            return
        if isinstance(self.layers, torch.fx.GraphModule):
            # Legacy FX GraphModule path: reset the mutable default state dict.
            import inspect
            sig = inspect.signature(self.layers.forward)
            if 'state' in sig.parameters:
                default_state = sig.parameters['state'].default
                if isinstance(default_state, dict):
                    self._reset_state_dict(default_state)
        elif hasattr(self.layers, "reset") and callable(getattr(self.layers, "reset")):
            self.layers.reset()

        self.states = None

    def _reset_state_dict(self, state_dict):
        for key in state_dict:
            if isinstance(state_dict[key], dict):
                self._reset_state_dict(state_dict[key])
            else:
                state_dict[key] = None


    def from_nir(self, nir_graph: Union[nir.NIRGraph, str]):
        self.layers = import_from_nir(nir_graph, self.quant_config, self.dt)

        # Spike Tracking
        if self.enable_tracking:
            self.register_forward_state_hooks([self.tracker.accumulate_states, self.tracker.accumulate_spikes])

        return self

    def register_forward_state_hooks(self, fn: List[Callable[[torch.nn.Module, tuple, dict, tuple, str], None]]):
        """
        Registers hooks for all state*ful* layers.

        Arguments:
            fn: A list of functions that take the output tensor and layer name as input.
        """
        # Get only concrete neuron classes from snntorch

        if not isinstance(self.layers, torch.nn.Module):
            raise ValueError("Layers must be a torch.nn.Module to register hooks.")
        for name, module in self.layers.named_modules():
            if self._is_module_stateful(module):
                # Use default arguments to capture values (avoid closure bug)

                def hooks(module, args, kwargs, output, layer_name=name):
                    for f_ in fn:
                        f_(module, args, kwargs, output, layer_name)
                module.register_forward_hook(hooks, with_kwargs=True)


    def to(self, *args, **kwargs):
        if self.layers is not None:
            self.layers.to(*args, **kwargs)
        super().to(*args, **kwargs)
        return self


    def _is_module_stateful(self, module: torch.nn.Module) -> bool:
        import snntorch

        # Get only concrete neuron classes from snntorch
        snntorch_classes = tuple(
            obj for obj in snntorch.__dict__.values()
            if inspect.isclass(obj)
            and issubclass(obj, torch.nn.Module)
            and obj.__module__.startswith('snntorch')
        )

        # Check if module is a norse or yana SNN
        signature = inspect.signature(module.forward)

        return "state" in signature.parameters or isinstance(module, torch.nn.RNNBase) or isinstance(module, snntorch_classes)
