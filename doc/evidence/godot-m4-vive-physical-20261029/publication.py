"""Device identifiers observed in diagnostic streams; raw bytes stay private."""
import re

_DEVICE_IDENTIFIER=re.compile(rb'(?:LHR|LHB)-[A-Za-z0-9]+',re.IGNORECASE)

def redact_devices(data:bytes)->bytes:
    return _DEVICE_IDENTIFIER.sub(b'<device-serial-redacted>',data)
