import math

from pytorch_lightning import Callback, Trainer
from pytorch_lightning.callbacks import ModelPruning
from pytorch_lightning.loggers import TensorBoardLogger
from pytorch_lightning.utilities.rank_zero import rank_zero_debug
import numpy as np

from yana.train.config.config import Cfg


class PruningScheduler:
    """dynamic pruning scheduler like https://lightning.ai/docs/pytorch/stable/advanced/pruning_quantization.html"""
    def __init__(self, sparsity_i, sparsity_f, num_epochs, frequency, mode="lin"):
        self.sparsity_i = sparsity_i
        self.sparsity_f = sparsity_f
        self.num_epochs = num_epochs
        self.frequency = frequency
        self.mode = mode

        self.current_sparsity = 0

    def __call__(self, epoch):
        amount = None
        if epoch % self.frequency == 0 and epoch < self.num_epochs:
            prune_step = int(epoch / self.frequency) + 1
            if self.current_sparsity == 0:
                self.current_sparsity = self.sparsity_i
                amount = self.sparsity_i
            else:
                if self.mode == "lin":
                    self.current_sparsity = self.current_sparsity * (prune_step / (prune_step - 1))
                    if self.current_sparsity <= self.sparsity_f:
                        amount = 1 / (int(1 / self.sparsity_i) - (prune_step - 1))
                elif self.mode == "exp":
                    amount = self.sparsity_i
                else:
                    raise Exception(f"Pruning mode {self.mode} unknown.")
        if amount is not None:
            return amount


class LogConnectionSparsityCallback(Callback):
    def __init__(self):
        super().__init__()

    def calculate_con_sparsity(self, model):
        # Calculate the connection sparsity
        total_params = 0
        zero_params = 0
        for name, param in model.named_buffers():
            if "mask" in name:
                total_params += param.numel()
                zero_params += (param == 0).sum().item()
        return zero_params / total_params

    def on_train_epoch_end(self, trainer, pl_module):
        con_sparsity = self.calculate_con_sparsity(pl_module)
        trainer.logger.log_metrics({"con_sparsity": con_sparsity}, trainer.current_epoch)


class ModelPruningAtEpochStart(ModelPruning):
    """
    A subclass of ModelPruning that applies pruning at the start of each training epoch,
    instead of at the end of the training epochs as in the original ModelPruning class.
    This prevents the last pruning step (without a subsequent fine-tuning epoch) to
    degrade the network performance.
    """

    def on_train_epoch_start(self, trainer, pl_module) -> None:
        """
        Applies pruning at the start of the training epoch.
        """
        rank_zero_debug("`ModelPruningAtEpochStart.on_train_epoch_start`. Applying pruning")
        self._run_pruning(pl_module.current_epoch)

    def on_train_epoch_end(self, trainer, pl_module) -> None:
        pass  # Do nothing, as pruning is now done at the start of the epoch

    def on_validation_epoch_end(self, trainer, pl_module) -> None:
        pass  # Do nothing, as pruning is now done at the start of the epoch


def do_iterative_pruning(model, cfg: Cfg, version: str, datamodule, devices):
        print("\nIterative Pruning of Model...\n")
        sparsity_i = cfg.pruning_cfg.pruning_per_step
        sparsity_f = cfg.pruning_cfg.max_pruning
        frequency = cfg.pruning_cfg.frequency
        method = cfg.pruning_cfg.method
        mode = cfg.pruning_cfg.mode

        if mode == "lin":
            pruning_epochs = math.ceil(sparsity_f / sparsity_i)
        elif mode == "exp":
            pruning_epochs = int(np.log(1 - sparsity_f) / np.log(1 - sparsity_i))
            sparsity_i = 1 - np.power(1 - sparsity_f, 1 / pruning_epochs)  # correct sparsity_i slightly for int number of pruning_epochs
        else:
            raise Exception(f"Pruning mode {mode} unknown.")

        pruning_scheduler = PruningScheduler(sparsity_i=sparsity_i, sparsity_f=sparsity_f, num_epochs=pruning_epochs, frequency=frequency, mode=mode)

        if method == "magnitude":
            pruning_callback = ModelPruningAtEpochStart("l1_unstructured", amount=pruning_scheduler, verbose=0)
        elif method == "random":
            pruning_callback = ModelPruningAtEpochStart("random_unstructured", amount=pruning_scheduler, verbose=0)
        else:
            raise Exception(f"Pruning method {method} unknown.")

        pruning_callbacks = [
            pruning_callback,
            LogConnectionSparsityCallback(),
        ]
        logger = TensorBoardLogger(save_dir=cfg.trainer_cfg.output_path, version=version, default_hp_metric=False)
        pruning_trainer = Trainer(
            max_epochs=pruning_epochs,
            accelerator="gpu",
            devices=[devices],
            log_every_n_steps=1,
            callbacks=pruning_callbacks,
            logger=logger,
        )
        print("Trainer output path:", pruning_trainer.logger.log_dir)
        model.train()
        pruning_trainer.fit(model, datamodule=datamodule)
