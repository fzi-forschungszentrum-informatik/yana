from typing import List, Optional

import pytorch_lightning as pl
from pytorch_lightning.callbacks import Callback

from .pruner import SimplePruner
from .scheduler import IncrementalPruningScheduler


class SimplePruningCallback(Callback):
    """PyTorch Lightning callback for simple incremental magnitude pruning.

    At the start of each epoch the scheduler is queried; if the epoch is a
    pruning step, the managed Linear layers are pruned to the scheduled target
    sparsity and the resulting sparsity is logged.
    """

    def __init__(self,
                 scheduler: IncrementalPruningScheduler,
                 pruner: SimplePruner,
                 layers: Optional[List[int]] = None,
                 verbose: bool = False):
        super().__init__()
        self.scheduler = scheduler
        self.pruner = pruner
        self.layers = layers if layers else list(range(len(pruner.layers)))
        self.verbose = verbose

    def on_train_start(self, trainer: pl.Trainer, pl_module: pl.LightningModule) -> None:
        self.scheduler.print_schedule()

    def on_train_epoch_start(self, trainer: pl.Trainer, pl_module: pl.LightningModule) -> None:
        target_sparsity = self.scheduler.check_pruning_step(trainer.current_epoch)
        if target_sparsity is None:
            return

        stats = self.pruner.prune_to_sparsity(target_sparsity, self.layers)
        actual_sparsity = stats["global_weight_sparsity"]

        if self.verbose:
            print(f"Epoch {trainer.current_epoch}: pruned to target sparsity "
                  f"{target_sparsity:.1%}, actual weight sparsity {actual_sparsity:.1%}")

        pl_module.log("prune/target_sparsity", target_sparsity, prog_bar=False, logger=True)
        pl_module.log("prune/actual_weight_sparsity", actual_sparsity, prog_bar=False, logger=True)
