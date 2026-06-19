import os
from typing import Optional

import pytorch_lightning as pl
from pytorch_lightning.callbacks import Callback

from .scheduler import IncrementalPruningScheduler


class PruningCheckpointCallback(Callback):
    """Save the best checkpoint of each pruning increment.

    Each pruning step raises the target sparsity and is followed by a window of
    fine-tuning epochs. This callback tracks the monitored metric within each
    sparsity window and keeps only the best-scoring checkpoint per increment.
    Checkpoints are named with their target sparsity so the deployment tooling
    can later select a specific sparsity level.
    """

    def __init__(self,
                 scheduler: IncrementalPruningScheduler,
                 monitor: str = "val/acc",
                 mode: str = "max",
                 verbose: bool = False):
        super().__init__()
        if mode not in ("max", "min"):
            raise ValueError(f"mode must be 'max' or 'min', got {mode}")
        self.scheduler = scheduler
        self.monitor = monitor
        self.mode = mode
        self.verbose = verbose

        self._current_sparsity: Optional[float] = None
        self._best_score: Optional[float] = None
        self._best_path: Optional[str] = None

    def _is_better(self, score: float) -> bool:
        if self._best_score is None:
            return True
        return score > self._best_score if self.mode == "max" else score < self._best_score

    def on_train_epoch_start(self, trainer: pl.Trainer, pl_module: pl.LightningModule) -> None:
        target_sparsity = self.scheduler.check_pruning_step(trainer.current_epoch)
        if target_sparsity is None:
            return
        # A new increment begins: reset best tracking for this window.
        self._current_sparsity = target_sparsity
        self._best_score = None
        self._best_path = None

    def on_validation_epoch_end(self, trainer: pl.Trainer, pl_module: pl.LightningModule) -> None:
        if self._current_sparsity is None or trainer.sanity_checking:
            return

        metric = trainer.callback_metrics.get(self.monitor)
        if metric is None:
            return
        score = float(metric)
        if not self._is_better(score):
            return

        assert trainer.logger is not None and trainer.logger.log_dir is not None, "No logger configured"
        ckpt_dir = os.path.join(trainer.logger.log_dir, "checkpoints")
        os.makedirs(ckpt_dir, exist_ok=True)
        new_path = os.path.join(
            ckpt_dir,
            f"sparsity={self._current_sparsity:.2f}-epoch={trainer.current_epoch}-val_acc={score:.4f}.ckpt",
        )

        # Only keep the best checkpoint of this increment.
        if self._best_path is not None and os.path.isfile(self._best_path):
            os.remove(self._best_path)

        trainer.save_checkpoint(new_path, weights_only=False)
        self._best_score = score
        self._best_path = new_path

        if self.verbose:
            print(f"Saved pruning checkpoint for sparsity {self._current_sparsity:.1%} "
                  f"({self.monitor}={score:.4f}): {os.path.basename(new_path)}")
