from importlib.metadata import version, PackageNotFoundError

try:
    __version__ = version("yana")
except PackageNotFoundError:
    __version__ = "unknown"
