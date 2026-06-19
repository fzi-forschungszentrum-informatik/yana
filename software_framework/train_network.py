import argparse
import os

from yana.train.utils import quantize_weights
from yana.train.config import Cfg
from yana.train.training import initialize_experiment, do_training, do_test
from yana.core.config import AcceleratorConfig


if __name__ == "__main__":
    # Parse configuration
    parser = argparse.ArgumentParser(description="Parse hierarchical command-line arguments.", formatter_class=argparse.MetavarTypeHelpFormatter)
    parser.add_argument("-c", "--config-path", type=str, default="yana/train/config/nmnist_feed_forward.yaml")
    parser.add_argument("-a", "--accelerator-config-path", type=str, default="yana/core/config/default/accelerator.yaml")
    parser.add_argument("-q", "--quantize", action="store_true")
    parser.add_argument("-C", "--checkpoint-dir", type=str)
    parser.add_argument("--no-train", action="store_true")
    parser.add_argument("--no-test", action="store_true")
    parser.add_argument("--no-logs", action="store_true")

    Cfg.add_args_to_parser(parser)
    args = parser.parse_args()

    # If given, use the checkpoint directory
    if args.checkpoint_dir and os.path.isdir(args.checkpoint_dir):
        config_path = os.path.join(args.checkpoint_dir, "parsed_config.yaml")
    else:
        config_path = args.config_path

    cfg = Cfg.from_yaml(config_path, args)
    acc_cfg = AcceleratorConfig.from_yaml(args.accelerator_config_path)
    assert acc_cfg.core_config_hidden is not None, "Hidden core config is required."
    quant_config = acc_cfg.core_config_hidden.quant_config

    if args.checkpoint_dir and os.path.isdir(args.checkpoint_dir):
        checkpoints_dir = os.path.join(args.checkpoint_dir, "checkpoints")
        checkpoint_files = []
        for root, dirs, files in os.walk(checkpoints_dir):
            for file in files:
                checkpoint_files.append(os.path.join(root, file))
        checkpoint_path = checkpoint_files[0]   # Use first checkpoint
        cfg.trainer_cfg.checkpoint_path = checkpoint_path

    # Train network
    trainer, model, data_module = initialize_experiment(cfg, acc_cfg, enable_logs=not args.no_logs)
    if not args.no_train:
        do_training(trainer, model, data_module)

    # Quantize network weights
    if args.quantize:
        print("\nQuantizing model weights...")
        quantize_weights(model, quant_config.format_weights.word_length, quant_config.format_weights.fraction_length)

    # Test (quantized) network performance
    if not args.no_test:
        do_test(trainer, model, data_module)

    print("Successfully finished training of SNN model.")
