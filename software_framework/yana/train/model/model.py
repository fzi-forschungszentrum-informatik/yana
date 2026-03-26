from dataclasses import dataclass
from typing import Any, Dict

import torch, torchmetrics
import pytorch_lightning as pl

from .networks.feed_forward import FeedForward


@dataclass
class OptimizerCfg:
    optimizer: str
    lr: float
    lr_scheduling: bool
    lr_scheduling_step_size: int
    lr_scheduling_fac: float
    spikerate_loss_coefficient: float
    weight_decay: float


@dataclass
class ModelCfg:
    network_type: str
    optimizer_cfg: OptimizerCfg
    network_cfg: Dict[str, Any]
    enable_spikerate_tracking: bool = True


class Model(pl.LightningModule):
    def __init__(self, cfg: ModelCfg, input_shape, output_features):
        super().__init__()
        self.save_hyperparameters()

        self.cfg = cfg

        self.decoder = lambda x: torch.nn.functional.log_softmax(x, dim=1)
        accuracy_args = {"task": "multiclass", "num_classes": output_features}
        self.train_acc = torchmetrics.Accuracy(**accuracy_args)
        self.valid_acc = torchmetrics.Accuracy(**accuracy_args)
        self.test_acc = torchmetrics.Accuracy(**accuracy_args)

        # Setup network
        if cfg.network_type == "feed_forward":
            self.network = FeedForward(
                input_shape=input_shape,
                output_features=output_features,
                enable_spikerate_tracking=cfg.enable_spikerate_tracking,
                **cfg.network_cfg,
            )
        else:
            raise Exception("Network type not recognized: {}".format(cfg.network_type))

    def forward(self, x):
        # info: shape of tensor
        # x.shape = [num_samples, batch_size, 1, sensor x, sensor y]
        # frame.shape = [batch_size, 1, sensor x, sensor y]
        # res.shape = [batch_size, num_classes]

        self.network.reset()
        for frame in x:
            res = self.network(frame)
        return self.decoder(res)

    def configure_optimizers(self):
        if self.cfg.optimizer_cfg.optimizer == "Adam":
            optimizer = torch.optim.Adam(self.parameters(), lr=self.cfg.optimizer_cfg.lr, weight_decay=self.cfg.optimizer_cfg.weight_decay)
        elif self.cfg.optimizer_cfg.optimizer == "RMSprop":
            optimizer = torch.optim.RMSprop(self.parameters(), lr=self.cfg.optimizer_cfg.lr)
        elif self.cfg.optimizer_cfg.optimizer == "SGD":
            optimizer = torch.optim.SGD(self.parameters(), lr=self.cfg.optimizer_cfg.lr)
        else:
            raise ValueError(f"Optimizer {self.optimizer} is not supported.")

        if self.cfg.optimizer_cfg.lr_scheduling:
            scheduler = torch.optim.lr_scheduler.StepLR(
                optimizer, 
                step_size=self.cfg.optimizer_cfg.lr_scheduling_step_size, 
                gamma=self.cfg.optimizer_cfg.lr_scheduling_fac
            )
            return [optimizer], [scheduler]
        else:
            return optimizer

    def predict_step(self, batch, batch_idx, dataloader_idx=0):
        with torch.no_grad():
            data, _ = batch
            data = data.permute([1, 0, 2, 3, 4])
            return self(data)

    def training_step(self, batch, batch_idx):
        x, y = batch
        x = x.permute([1, 0, 2, 3, 4])
        output = self(x)
        loss, cat_loss, spike_loss, average_network_spike_rate = self._calculate_loss(output, y, x.shape[0])

        self.log("train/loss", loss.detach(), on_step=True, prog_bar=True, logger=True)
        self.log("train/acc", self.train_acc(output, y), on_step=False, on_epoch=True, prog_bar=True)
        self.log("train/cat_loss", cat_loss.detach(), on_step=False, on_epoch=True, prog_bar=True, logger=True)
        self.log("train/spike_loss", spike_loss.detach(), on_step=False, on_epoch=True, prog_bar=True, logger=True)
        self.log("train/avg_spikerate", average_network_spike_rate.detach(), on_step=False, on_epoch=True, prog_bar=True, logger=True)
        return loss

    def validation_step(self, batch, batch_idx):
        with torch.no_grad():
            x, y = batch
            x = x.permute([1, 0, 2, 3, 4])
            output = self(x)
            loss, cat_loss, spike_loss, average_network_spike_rate = self._calculate_loss(output, y, x.shape[0])

            self.log("val/loss", loss.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
            self.log("val/acc", self.valid_acc(output, y), on_step=False, on_epoch=True, prog_bar=True, logger=True)
            self.log("val/cat_loss", cat_loss.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
            self.log("val/spike_loss", spike_loss.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
            self.log("val/avg_spikerate", average_network_spike_rate.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
            return loss

    def test_step(self, batch, batch_idx):
        # with torch.no_grad():
        with torch.inference_mode():
            x, y = batch
            x = x.permute([1, 0, 2, 3, 4])
            output = self(x)
            loss, cat_loss, spike_loss, average_network_spike_rate = self._calculate_loss(output, y, x.shape[0])

            self.log("test/loss", loss.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
            self.log("test/acc", self.test_acc(output, y), on_step=False, on_epoch=True, prog_bar=True, logger=True)
            self.log("test/cat_loss", cat_loss.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
            self.log("test/spike_loss", spike_loss.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)
            self.log("test/avg_spikerate", average_network_spike_rate.detach(), on_step=False, on_epoch=True, prog_bar=False, logger=True)

    def _calculate_loss(self, output, target, num_timesteps):
        # Categorical loss
        cat_loss = torch.nn.functional.nll_loss(output, target)

        # Spike rate loss
        if not self.cfg.enable_spikerate_tracking:
            return [cat_loss, cat_loss, torch.tensor(0.0), torch.tensor(0.0)]

        if not hasattr(self.network, "accumulated_spikes"):
            raise ValueError(f"Network {self.cfg.network_type} doesnt support spikerate tracking")

        spike_loss, average_network_spike_rate = self._calculate_spike_loss(num_timesteps, 0.0)
        loss = cat_loss + spike_loss * self.cfg.optimizer_cfg.spikerate_loss_coefficient

        return [loss, cat_loss, spike_loss, average_network_spike_rate]

    def _calculate_spike_loss(self, num_timesteps, target_spikerate):
        total_neurons = torch.tensor(0.0, device=self.network.device)
        total_spikerate = torch.tensor(0.0, device=self.network.device)
        total_squared_error = torch.tensor(0.0, device=self.network.device)

        for layer_name in self.network.accumulated_spikes:
            neuron_spikes = torch.flatten(self.network.accumulated_spikes[layer_name])
            total_neurons += neuron_spikes.shape[0]

            total_spikerate += torch.sum(neuron_spikes) / num_timesteps
            total_squared_error += torch.sum(torch.pow(neuron_spikes / num_timesteps - target_spikerate, 2))

        network_spike_rate = total_spikerate / total_neurons

        # MSE spike rate loss
        spike_loss = total_squared_error / total_neurons

        return [spike_loss, network_spike_rate]
