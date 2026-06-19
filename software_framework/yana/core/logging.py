from enum import Enum

class LogLevel(Enum):
    ERROR = 0
    WARNING = 1
    INFO = 2
    VERBOSE = 3
    TRACE = 4

LOG_LEVEL = LogLevel.WARNING

def set_log_level(log_level: LogLevel):
    global LOG_LEVEL
    LOG_LEVEL = log_level

def log(*values: object, log_level: LogLevel):
    if log_level.value <= LOG_LEVEL.value:
        print(*values)

def error(*values: object):
    log(*values, log_level=LogLevel.ERROR)

def warn(*values: object):
    log(*values, log_level=LogLevel.WARNING)

def info(*values: object):
    log(*values, log_level=LogLevel.INFO)

def verbose(*values: object):
    log(*values, log_level=LogLevel.VERBOSE)

def trace(*values: object):
    log(*values, log_level=LogLevel.TRACE)
