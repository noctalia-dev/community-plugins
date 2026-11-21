"""Environment for programs started from Umbriel Settings (xdg-open, gio, editors, apps, umbriel)."""

import os

# The AppImage entrypoint overrides these to isolate its bundled Python and records the host's
# values (UMBRIEL_SETTINGS_HOST_<NAME>) so launched programs see the user's original environment.
APPIMAGE_ENV_MARKER = "UMBRIEL_SETTINGS_APPIMAGE_ENV"
HOST_PYTHON_VARS = ("PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONUSERBASE", "PYTHONNOUSERSITE")


def child_env(environ=None):
    """Return the environment for launched programs, restoring host Python variables inside the AppImage."""
    env = dict(os.environ if environ is None else environ)
    if not env.pop(APPIMAGE_ENV_MARKER, None):
        return env
    for name in HOST_PYTHON_VARS:
        saved = env.pop(f"UMBRIEL_SETTINGS_HOST_{name}", None)
        if saved is None:
            env.pop(name, None)
        else:
            env[name] = saved
    return env
