import os
from typing import Optional

import tabulate
import torch
import yaml
from pytorch_lightning import Trainer
from pytorch_lightning.callbacks import ModelSummary, LearningRateMonitor
from pytorch_lightning.loggers import TensorBoardLogger

from .pruner import SimplePruner
from .scheduler import IncrementalPruningScheduler
from .callback import SimplePruningCallback
from .checkpoint import PruningCheckpointCallback
from yana.train.config import Cfg


def do_pruning(model, cfg: Cfg, version: Optional[str], datamodule, devices,
               save_dir: Optional[str] = None, study_name: str = "lightning_logs"):
    print("\nStarting incremental pruning...\n")

    scheduler_cfg = cfg.pruning_cfg.scheduler_cfg
    scheduler = IncrementalPruningScheduler(
        target_sparsity=scheduler_cfg["target_sparsity"],
        increment=scheduler_cfg["increment"],
        frequency=scheduler_cfg.get("frequency", 5),
    )

    pruner = SimplePruner(model.network)
    pruning_callbacks = [
        SimplePruningCallback(
            scheduler=scheduler,
            pruner=pruner,
            layers=cfg.pruning_cfg.pruned_layers,
        ),
        PruningCheckpointCallback(scheduler=scheduler),
        ModelSummary(max_depth=3),
        LearningRateMonitor(logging_interval="epoch"),
    ]

    accelerator = "gpu" if torch.cuda.is_available() else "cpu"
    trainer_devices = [devices] if accelerator == "gpu" else 1

    if save_dir is None:
        save_dir = cfg.trainer_cfg.output_path
    logger = TensorBoardLogger(save_dir=save_dir, name=study_name, version=version, default_hp_metric=False)
    pruning_trainer = Trainer(
        max_epochs=scheduler.total_epochs(),
        accelerator=accelerator,
        devices=trainer_devices,
        log_every_n_steps=1,
        callbacks=pruning_callbacks,
        logger=logger,
        deterministic="warn",
    )
    print("Pruning output path:", logger.log_dir)

    # Make the pruning run self-contained so it can be deployed directly.
    os.makedirs(logger.log_dir, exist_ok=True)
    with open(os.path.join(logger.log_dir, "parsed_config.yaml"), "w") as f:
        yaml.safe_dump(cfg.to_dict(), f, sort_keys=False)

    model.train()
    pruning_trainer.fit(model, datamodule=datamodule)

    stats = pruner.get_sparsity_stats()
    layer_stats = stats.pop("layer_stats")

    print("Global sparsity stats:")
    print(tabulate.tabulate(stats.items(), headers=["Metric", "Value"], tablefmt="rounded_grid"))
    for i, layer_stat in enumerate(layer_stats):
        print(f"Linear layer {i} sparsity stats:")
        print(tabulate.tabulate(layer_stat.items(), headers=["Metric", "Value"], tablefmt="rounded_grid"))

    return logger.log_dir
