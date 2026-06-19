from torch.optim.lr_scheduler import LRScheduler

class WarmupScheduler(LRScheduler):
    """
    A scheduler that performs linear warmup for the first few epochs,
    then switches to another specified scheduler.

    Args:
        optimizer: PyTorch optimizer
        warmup_epochs: Number of epochs for warmup phase
        main_scheduler: The scheduler to use after warmup (should be initialized separately)
        warmup_start_lr: Starting learning rate for warmup (default: 0)
        last_epoch: The index of last epoch (default: -1)
        verbose: If True, prints a message to stdout for each update (default: False)
    """

    def __init__(self, optimizer, warmup_epochs, main_scheduler,
                 warmup_start_lr=0, last_epoch=-1):
        self.warmup_epochs = warmup_epochs
        self.main_scheduler = main_scheduler
        self.warmup_start_lr = warmup_start_lr

        # Store the target learning rates (what we want to reach after warmup)
        self.target_lrs = [group['lr'] for group in optimizer.param_groups]

        # Initialize with warmup start learning rate
        for group in optimizer.param_groups:
            group['lr'] = warmup_start_lr

        super().__init__(optimizer, last_epoch)

    def get_lr(self):
        if self.last_epoch < self.warmup_epochs:
            # Warmup phase: linear interpolation
            warmup_factor = (self.last_epoch + 1) / self.warmup_epochs
            return [self.warmup_start_lr + (target_lr - self.warmup_start_lr) * warmup_factor
                    for target_lr in self.target_lrs]
        else:
            # Use main scheduler
            # Adjust the main scheduler's last_epoch to account for warmup
            self.main_scheduler.last_epoch = self.last_epoch - self.warmup_epochs
            return self.main_scheduler.get_lr()

    def step(self, epoch=None):
        if epoch is None:
            epoch = self.last_epoch + 1

        self.last_epoch = epoch

        if epoch < self.warmup_epochs:
            # During warmup, use our own logic
            for param_group, lr in zip(self.optimizer.param_groups, self.get_lr()):
                param_group['lr'] = lr
        else:
            # After warmup, delegate to main scheduler
            # Make sure main scheduler is at the correct step
            main_epoch = epoch - self.warmup_epochs
            if hasattr(self.main_scheduler, 'step'):
                self.main_scheduler.step(main_epoch)

        self._last_lr = [group['lr'] for group in self.optimizer.param_groups]

    def reset(self):
        # Don't reset to -1 because of delayed call of scheduler.step()
        self.last_epoch = 0
        self.main_scheduler.last_epoch = 0

        # Apply to optimizer immediately
        for group in self.optimizer.param_groups:
            group["lr"] = self.warmup_start_lr
        self._last_lr = [self.warmup_start_lr] * len(self.optimizer.param_groups)
