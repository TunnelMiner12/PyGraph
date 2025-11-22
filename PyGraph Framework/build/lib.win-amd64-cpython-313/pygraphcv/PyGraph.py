import base64
import zlib
import os
import sys
import pathlib
import time
# --- FIX: Updated imports for Pylance compatibility and modern Python ---
# setup and Extension are now imported directly from setuptools.
from setuptools import setup, Extension
# Distribution and the build_ext command are imported from their new locations in setuptools.
from setuptools.dist import Distribution
from setuptools.command.build_ext import build_ext as _build_ext
# -------------------------------------------------------------------
from Cython.Build import cythonize

# Note: This script requires Cython, setuptools, and numpy to be installed.
#       pip install cython setuptools numpy

# --- Configuration ---
CYTHON_MODULE_NAME = '_pygraph_core'
PYX_FILE = f"{CYTHON_MODULE_NAME}.pyx"

# --- Magic Variable for State Persistence ---
# This variable stores the zlib-compressed and base64-encoded content of the
# last successfully compiled .pyx file.
# DO NOT EDIT THIS LINE MANUALLY after the initial run; the script manages it.
_LAST_COMPILED_PYX_CONTENT = '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'

# --- Helper Functions ---

def _encode_content_cython(content: str) -> str:
    """Compresses and Base64 encodes content."""
    # Use compression (level 9) for efficiency
    compressed = zlib.compress(content.encode('utf-8'), 9)
    return base64.b64encode(compressed).decode('ascii')

def _decode_content_cython(encoded_content: str) -> str:
    """Decodes and decompresses content."""
    if not encoded_content:
        return ""
    try:
        compressed = base64.b64decode(encoded_content.encode('ascii'))
        return zlib.decompress(compressed).decode('utf-8')
    except (zlib.error, base64.binascii.Error) as e:
        print(f"Warning: Failed to decode stored content: {e}. Assuming PYX file is new or changed.")
        return "DECODING_ERROR_FORCE_RECOMPILE"

def _update_self_file(new_encoded_content: str):
    """
    Reads the current script file and updates the magic variable
    _LAST_COMPILED_PYX_CONTENT with the new encoded content.
    
    FIX: Corrected variable name lookup to use the string literal, 
    as the variable itself is a string and does not have a __name__ attribute.
    """
    script_path = pathlib.Path(os.path.abspath(__file__))
    try:
        # Read all lines from the current file
        with open(script_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()

        # The actual string name of the magic variable is hardcoded here.
        MAGIC_VAR_NAME = "_LAST_COMPILED_PYX_CONTENT"
        target_prefix = f'{MAGIC_VAR_NAME} = '
        
        for i, line in enumerate(lines):
            # We look for the line starting with the magic variable name
            if line.strip().startswith(target_prefix):
                # Use repr() to ensure the string is quoted correctly (single or double quotes)
                new_line = f'{MAGIC_VAR_NAME} = {repr(new_encoded_content)}\n'
                lines[i] = new_line
                break
        else:
            print(f"Error: Magic variable '{MAGIC_VAR_NAME}' not found in script. Self-editing failed.")
            return

        # Write the updated lines back to the file
        with open(script_path, 'w', encoding='utf-8') as f:
            f.writelines(lines)

        print(f"File updated successfully. New content size: {len(new_encoded_content)} bytes.")

    except Exception as e:
        print(f"CRITICAL ERROR during self-editing: {e}")
        # Exit to prevent further damage
        sys.exit(1)


def compile_pygraph_core_if_needed():
    """
    The main compilation function. It checks if the .pyx file has changed,
    performs the Cython compilation if necessary, and saves the new content
    hash back into this script.
    """
    global _LAST_COMPILED_PYX_CONTENT # Access the magic variable

    try:
        # These imports are needed for the compilation step
        import numpy
        # setuptools.Extension is already imported
    except ImportError as e:
        print(f"Required dependency missing: {e}. Please install using 'pip install numpy cython setuptools'")
        return

    pyx_path = pathlib.Path(PYX_FILE)
    if not pyx_path.exists():
        print(f"Error: Required Cython source file '{PYX_FILE}' not found.")
        print("Please ensure you have created this file (e.g., using the provided block) and try again.")
        return

    # 1. Get current PYX content
    current_pyx_content = pyx_path.read_text(encoding='utf-8')
    current_encoded_content = _encode_content_cython(current_pyx_content)

    # 2. Get last compiled PYX content from self-stored variable
    last_pyx_content = _decode_content_cython(_LAST_COMPILED_PYX_CONTENT)

    if current_pyx_content == last_pyx_content:
        print(f"'{PYX_FILE}' content is unchanged. Skipping compilation.")
        return

    print(f"'{PYX_FILE}' content changed or not compiled before. Starting compilation...")
    print(f"(Current content size: {len(current_pyx_content)} bytes. Last compiled size: {len(last_pyx_content)} bytes)")

    # 3. Perform Compilation
    try:
        # Define the extension module (similar to setup.py)
        ext_modules = [
            Extension(
                CYTHON_MODULE_NAME,
                [PYX_FILE],
                include_dirs=[numpy.get_include()],
                # Recommended optimization flags
            )
        ]

        # Use the programmatic way to execute build_ext --inplace
        # cythonize first converts the .pyx to .c
        cythonized_exts = cythonize(ext_modules, language_level="3")

        # Then use distutils/setuptools infrastructure to build the C file into a shared library (.so or .pyd)
        # We manually construct the Distribution and run the build_ext command in 'inplace' mode.
        dist = Distribution({'ext_modules': cythonized_exts})
        cmd = _build_ext(dist)
        cmd.inplace = True # Equivalent to --inplace
        cmd.ensure_finalized()
        cmd.run() # This executes the final compilation!

        # 4. If compilation succeeded, update the self-file
        print("Compilation successful! Updating source file with new PYX content...")
        _update_self_file(current_encoded_content)
        
        # 5. Inform user
        print(f"\nSuccessfully compiled and updated '{CYTHON_MODULE_NAME}'.")

    except Exception as e:
        print(f"\n=======================================================")
        print(f"COMPILATION FAILED: {e}")
        print("The source file was NOT updated. Fix the error in the .pyx file.")
        print(f"=======================================================\n")
        # Do not update the file if compilation failed
        pass

# Run the main compilation logic
compile_pygraph_core_if_needed()
#from _pygraph_core import *
