from typing import Callable, List

from yana.train.config import ModelCfg

import torch, torchmetrics
import pytorch_lightning as pl
import snntorch.functional as SF

from yana.core.config import AcceleratorConfig

from .lr_scheduler import WarmupScheduler
from .networks import import_network


class Decoder:
    def __init__(self):
        self.transforms: List[Callable[[torch.Tensor], torch.Tensor]] = []

    def append(self, transform: Callable[[torch.Tensor], torch.Tensor]):
        self.transforms.append(transform)

    def __call__(self, x: torch.Tensor) -> torch.Tensor:
        for transform in self.transforms:
            x = transform(x)
        return x


class Model(pl.LightningModule):
    def __init__(self, cfg: ModelCfg, acc_cfg: AcceleratorConfig, input_shape, output_features):
        super().__init__()
        self.save_hyperparameters()

        self.cfg = cfg

        # Decoder expects array of outputs for each timestep:
        # Dimension: [num_ts, batch_size, out_features]
        self.decoder = Decoder()
        for decoder_transform in cfg.decoder_transforms:
            match decoder_transform:
                case "sum":
                    self.decoder.append(lambda x: x.sum(dim=0))
                case "average":
                    self.decoder.append(lambda x: x.sum(dim=0) / len(x))
                case "last_average":
                    self.decoder.append(lambda x: x[-1] / len(x))
                case "pick_last":
                    self.decoder.append(lambda x: x[-1])
                case "log_softmax":
                    self.decoder.append(lambda x: torch.nn.functional.log_softmax(x, dim=1))
                case _:
                    raise ValueError(f"Unknown decoder transforms: {decoder_transform}")

        match cfg.optimizer_cfg.loss:
            case "nll":
                self.loss_fn = torch.nn.functional.nll_loss
            case "cross_entropy":
                self.loss_fn = torch.nn.functional.cross_entropy
            case "mse_count":
                self.loss_fn = SF.mse_count_loss()
            case "ce_count":
                self.loss_fn = SF.ce_count_loss()
            case "mse":
                self.loss_fn = torch.nn.functional.mse_loss
            case "mae":
                self.loss_fn = torch.nn.functional.l1_loss
            case _:
                raise ValueError(f"Unknown loss type: {cfg.optimizer_cfg.loss}")

        accuracy_args = {"task": "multiclass", "num_classes": output_features}
        self.train_acc = torchmetrics.Accuracy(**accuracy_args)
        self.valid_acc = torchmetrics.Accuracy(**accuracy_args)
        self.test_acc = torchmetrics.Accuracy(**accuracy_args)
        
        NetworkClass = import_network(cfg.network_type)
        self.network = NetworkClass(
            input_shape=input_shape,
            output_features=output_features,
            enable_tracking=cfg.enable_tracking,
            network_cfg=cfg.network_cfg,
            accelerator_cfg=acc_cfg
        )

    def forward(self, x):
        # info: shape of tensor
        # x.shape = [num_samples, batch_size, 1, sensor x, sensor y]
        # frame.shape = [batch_size, 1, sensor x, sensor y]
        # res.shape = [batch_size, num_classes]

        self.network.reset()
        outputs = []
        for frame in x:
            outputs.append(self.network(frame))

        outputs = torch.stack(outputs)
        return self.decoder(outputs)

    def configure_optimizers(self):
        match self.cfg.optimizer_cfg.optimizer:
            case "Adam":
                optimizer = torch.optim.Adam(self.parameters(), lr=self.cfg.optimizer_cfg.lr, weight_decay=self.cfg.optimizer_cfg.weight_decay)
            case "AdamW":
                optimizer = torch.optim.AdamW(self.parameters(), lr=self.cfg.optimizer_cfg.lr, weight_decay=self.cfg.optimizer_cfg.weight_decay)
            case "RMSprop":
                optimizer = torch.optim.RMSprop(self.parameters(), lr=self.cfg.optimizer_cfg.lr)
            case "SGD":
                optimizer = torch.optim.SGD(self.parameters(), lr=self.cfg.optimizer_cfg.lr)
            case _:
                raise ValueError(f"Optimizer {self.cfg.optimizer_cfg.optimizer} is not supported.")

        if self.cfg.optimizer_cfg.lr_scheduler:
            match self.cfg.optimizer_cfg.lr_scheduler:
                case "step":
                    main_scheduler = torch.optim.lr_scheduler.StepLR(
                        optimizer,
                        step_size=self.cfg.optimizer_cfg.lr_scheduler_cfg["step_size"],
                        gamma=self.cfg.optimizer_cfg.lr_scheduler_cfg["factor"]
                    )
                case "cosine":
                    main_scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
                    optimizer, T_max=self.cfg.optimizer_cfg.lr_scheduler_cfg["max_epoch"],
                    eta_min=1e-2*self.cfg.optimizer_cfg.lr
                )
                case "reduce_on_plateau":
                    main_scheduler = torch.optim.lr_scheduler.ReduceLROnPlateau(
                        optimizer,
                        mode='min',
                        factor=self.cfg.optimizer_cfg.lr_scheduler_cfg["factor"],
                        patience=self.cfg.optimizer_cfg.lr_scheduler_cfg["patience"],
                        threshold=self.cfg.optimizer_cfg.lr_scheduler_cfg.get("threshold", 1e-4),
                    )
                case "constant":
                    main_scheduler = torch.optim.lr_scheduler.ConstantLR(optimizer, factor=1.0)
                case _:
                    raise ValueError(f"Unknown learning rate scheduler: {self.cfg.optimizer_cfg.lr_scheduler}")

            if (
                self.cfg.optimizer_cfg.lr_scheduler_cfg is not None and
                "warmup" in self.cfg.optimizer_cfg.lr_scheduler_cfg and
                self.cfg.optimizer_cfg.lr_scheduler_cfg["warmup"] > 0
            ):
                scheduler = WarmupScheduler(
                    optimizer,
                    warmup_epochs=self.cfg.optimizer_cfg.lr_scheduler_cfg["warmup"],
                    main_scheduler=main_scheduler
                )
            else:
                scheduler = main_scheduler

            return [optimizer], [scheduler]
        else:
            return optimizer

    # Required for using custom or multiple hyperparameter metrics (init. TBLogger with default_hp_metric=False)
    def on_train_start(self):
        self.logger.log_hyperparams(self.hparams, {"val/acc": 0})   # type: ignore

    def predict_step(self, batch, batch_idx, dataloader_idx=0):
        with torch.no_grad():
            data, _ = batch
            data = data.permute(1, 0, *range(2, data.ndim))
            return self(data)

    def training_step(self, batch, batch_idx):
        x, y = batch

        x = x.permute(1, 0, *range(2, x.ndim))
        num_timesteps = x.shape[0]
        batch_size = x.shape[1]

        output = self(x)
        loss, cat_loss, spike_loss, average_network_spike_rate, total_spikes = self._calculate_loss(output, y, num_timesteps, x)
        total_spikes_per_sample = total_spikes / batch_size

        # Check if output has time dimension and sum on time dimension
        # With time dimension:      [T, B, F]   (Time, Batch Size, Features)
        # Without time dimension:   [B, F]      (Batch Size, Features)
        if output.ndim == 3:
            output = output.sum(dim=0)

        self.log("train/loss", loss.detach(), on_step=True, prog_bar=True, logger=True)
        self.log("train/acc", self.train_acc(output, y), on_step=False, on_epoch=True, prog_bar=True)
        self.log("train/cat_loss", cat_loss.detach(), on_step=False, on_epoch=True, prog_bar=True, logger=True)
        if self.cfg.enable_tracking:
            self.log("train/spike_loss", spike_loss.detach(), on_step=False, on_epoch=True, prog_bar=True, logger=True)
            self.log("train/avg_spikerate", average_network_spike_rate.detach(), on_step=False, on_epoch=True, prog_bar=True, logger=True)
            self.log("train/avg_spike_count", total_spikes_per_sample.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
            for layer_name in self.network.tracker["accumulated_spikes"]:
                layer_spikes = self.network.tracker["accumulated_spikes"][layer_name].detach().sum()
                layer_spike_rate = layer_spikes / self.network.tracker["accumulated_spikes"][layer_name].detach().numel()
                self.log(f"train/avg_spike_count_{layer_name}", (layer_spikes / batch_size), on_step=False, on_epoch=True, prog_bar=False, logger=True)
                self.log(f"train/avg_spikerate_{layer_name}", layer_spike_rate, on_step=False, on_epoch=True, prog_bar=False, logger=True)

        # Log predictions and loss
        num_correct_preds = len(output) - (output.argmax(1) - y).count_nonzero()
        return loss

    def validation_step(self, batch, batch_idx):
        with torch.no_grad():
            x, y = batch
            x = x.permute(1, 0, *range(2, x.ndim))
            num_timesteps = x.shape[0]
            batch_size = x.shape[1]

            output = self(x)
            loss, cat_loss, spike_loss, average_network_spike_rate, total_spikes = self._calculate_loss(output, y, num_timesteps, x)
            total_spikes_per_sample = total_spikes / batch_size

            # Check if output has time dimension and sum on time dimension
            if output.shape[0] == x.shape[0] and output.ndim > 2:
                output = output.sum(dim=0)

            self.log("val/loss", loss.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
            self.log("val/acc", self.valid_acc(output, y), on_step=False, on_epoch=True, prog_bar=True, logger=True)
            self.log("val/cat_loss", cat_loss.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
            if self.cfg.enable_tracking:
                self.log("val/spike_loss", spike_loss.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
                self.log("val/avg_spikerate", average_network_spike_rate.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
                self.log("val/avg_spike_count", total_spikes_per_sample.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
                for layer_name in self.network.tracker["accumulated_spikes"]:
                    layer_spikes = self.network.tracker["accumulated_spikes"][layer_name].detach().sum()
                    layer_spike_rate = layer_spikes / self.network.tracker["accumulated_spikes"][layer_name].detach().numel()
                    self.log(f"val/avg_spike_count_{layer_name}", (layer_spikes / batch_size), on_step=False, on_epoch=True, prog_bar=False, logger=True)
                    self.log(f"val/avg_spikerate_{layer_name}", layer_spike_rate, on_step=False, on_epoch=True, prog_bar=False, logger=True)

            # Log predictions and loss
            num_correct_preds = len(output) - (output.argmax(1) - y).count_nonzero()
            return loss

    def test_step(self, batch, batch_idx):
        with torch.inference_mode():
            x, y = batch
            x = x.permute(1, 0, *range(2, x.ndim))
            num_timesteps = x.shape[0]
            batch_size = x.shape[1]

            output = self(x)
            loss, cat_loss, spike_loss, average_network_spike_rate, total_spikes = self._calculate_loss(output, y, num_timesteps, x)
            total_spikes_per_sample = total_spikes / batch_size

            # Check if output has time dimension and sum on time dimension
            if output.shape[0] == x.shape[0] and output.ndim > 2:
                output = output.sum(dim=0)

            self.log("test/loss", loss.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
            self.log("test/acc", self.test_acc(output, y), on_step=False, on_epoch=True, prog_bar=True, logger=True)
            self.log("test/cat_loss", cat_loss.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
            if self.cfg.enable_tracking:
                self.log("test/spike_loss", spike_loss.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
                self.log("test/avg_spikerate", average_network_spike_rate.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
                self.log("test/avg_spike_count", total_spikes_per_sample.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
                for layer_name in self.network.tracker["accumulated_spikes"]:
                    layer_spikes = self.network.tracker["accumulated_spikes"][layer_name].detach().sum()
                    layer_spike_rate = layer_spikes / self.network.tracker["accumulated_spikes"][layer_name].detach().numel()
                    self.log(f"test/avg_spike_count_{layer_name}", (layer_spikes / batch_size), on_step=False, on_epoch=True, prog_bar=False, logger=True)
                    self.log(f"test/avg_spikerate_{layer_name}", layer_spike_rate, on_step=False, on_epoch=True, prog_bar=False, logger=True)

    def _calculate_loss(self, output, target, num_timesteps, input: torch.Tensor):
        # Categorical loss
        if isinstance(self.loss_fn, SF.loss.mse_count_loss):
            if self.cfg.optimizer_cfg.loss_params:
                if "rate_multiplier" in self.cfg.optimizer_cfg.loss_params:
                    # Scale the desired output activity with the input activity
                    input_spike_rate = input.sum() / input.numel()
                    target_correct_rate = input_spike_rate * self.cfg.optimizer_cfg.loss_params["rate_multiplier"]
                    self.loss_fn.correct_rate = target_correct_rate
                else:
                    # Apply fixed rate targets
                    self.loss_fn.correct_rate = self.cfg.optimizer_cfg.loss_params["correct_rate"]
                    self.loss_fn.incorrect_rate = self.cfg.optimizer_cfg.loss_params["incorrect_rate"]
            else:
                self.loss_fn.correct_rate = 0.8     # type: ignore
                self.loss_fn.incorrect_rate = 0.2   # type: ignore

        train_loss = self.loss_fn(output, target)

        # Spike rate loss
        if not self.cfg.enable_tracking:
            return [train_loss, train_loss, torch.tensor(0.0), torch.tensor(0.0), torch.tensor(0.0)]

        if hasattr(self.network, "tracker") and "accumulated_spikes" in self.network.tracker:
            spike_loss, average_network_spike_rate, total_spikes = self._calculate_spike_loss(num_timesteps, self.cfg.optimizer_cfg.spikerate_target)
            scaled_spike_loss = spike_loss * self.cfg.optimizer_cfg.spikerate_loss_coefficient
        else:
            scaled_spike_loss = average_network_spike_rate = total_spikes = torch.as_tensor(0.0)

        loss = train_loss + scaled_spike_loss
        return [loss, train_loss, scaled_spike_loss, average_network_spike_rate, total_spikes]

    def _calculate_spike_loss(self, num_timesteps, target_spikerate):
        total_neurons = torch.tensor(0.0, device=self.network.device)
        total_spikerate = torch.tensor(0.0, device=self.network.device)
        total_spikes = torch.tensor(0.0, device=self.network.device)

        for layer_name in self.network.tracker["accumulated_spikes"]:
            neuron_spikes = torch.flatten(self.network.tracker["accumulated_spikes"][layer_name])
            total_neurons += neuron_spikes.shape[0]

            total_spikes += torch.sum(neuron_spikes)
            total_spikerate += torch.sum(neuron_spikes) / num_timesteps

        network_spike_rate = total_spikerate / total_neurons

        # global spike rate loss (MSE with target spikerate)
        spike_loss = torch.pow(network_spike_rate - target_spikerate, 2)

        return [spike_loss, network_spike_rate, total_spikes]

    def to(self, *args, **kwargs):
        super().to(*args, **kwargs)
        self.network.to(*args, **kwargs)
        return self
