from abc import ABC

class TraceInterface(ABC):
    tracing: bool = False

    def set_tracing(self, tracing: bool):
        self.tracing = tracing

    def __enter__(self):
        self.set_tracing(True)
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.set_tracing(False)
        return False
