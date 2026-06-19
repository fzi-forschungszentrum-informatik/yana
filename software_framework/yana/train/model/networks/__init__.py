import importlib
from typing import Any


def _snake_to_camel(name: str) -> str:
    parts = name.split("_")
    return "".join(p.capitalize() for p in parts if p)


def import_network(module_basename: str) -> Any:
    """
    Dynamically import a network class from a submodule by basename.

    Examples:
    - import_network("feed_forward") -> returns class `FeedForward` from feed_forward.py
    - import_network("deep_conv") -> returns class `DeepConv` from deep_conv.py

    Resolution strategy:
    1) Import submodule `.module_basename` relative to this package.
    2) If the module defines `__all__` with exactly one public class name, return that.
    3) Otherwise, derive CamelCase name from snake_case (e.g., feed_forward -> FeedForward)
       and return the attribute with that name if present.
    4) If multiple public classes exist and no clear single target, raise a descriptive error.
    """
    if not module_basename or not isinstance(module_basename, str):
        raise ValueError("module_basename must be a non-empty string")

    try:
        module = importlib.import_module(f".{module_basename}", package=__name__)
    except ModuleNotFoundError as e:
        raise ModuleNotFoundError(
            f"Could not find submodule '{module_basename}' under '{__name__}'."
        ) from e

    # If module explicitly declares __all__, prefer it.
    if hasattr(module, "__all__") and isinstance(module.__all__, (list, tuple)):
        public = [n for n in module.__all__ if isinstance(n, str)]
        if len(public) == 1:
            target = public[0]
            try:
                return getattr(module, target)
            except AttributeError:
                raise ImportError(
                    f"Module '{module.__name__}' declares __all__=['{target}'] but does not define it."
                )
        elif len(public) > 1:
            raise ImportError(
                f"Module '{module.__name__}' exposes multiple names in __all__: {public}."
                " Specify which one to import or reduce to a single exported class."
            )

    # Fall back to CamelCase derived name
    class_name = _snake_to_camel(module_basename)
    if hasattr(module, class_name):
        return getattr(module, class_name)

    # If no camel-case match, try to find a single public class by inspection
    candidates = []
    for name in dir(module):
        if name.startswith("_"):
            continue
        attr = getattr(module, name)
        # Heuristic: return classes only
        if isinstance(attr, type):
            candidates.append(name)

    if len(candidates) == 1:
        return getattr(module, candidates[0])
    elif len(candidates) > 1:
        raise ImportError(
            f"Ambiguous: multiple public classes found in module '{module.__name__}': {candidates}."
            " Define __all__ with a single class or use a unique CamelCase name."
        )

    raise ImportError(
        f"No suitable class found in module '{module.__name__}'."
        " Ensure the class is public or define __all__ with a single class name."
    )


__all__ = ["import_network"]
