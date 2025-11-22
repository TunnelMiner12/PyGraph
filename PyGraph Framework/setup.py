from setuptools import setup, Extension
from Cython.Build import cythonize
import numpy
import os
from pathlib import Path
import sys 

# --- Configuration ---
PROJECT_NAME = 'pygraphcv' 
VERSION = '0.0.2'
CYTHON_MODULE_NAME = '_pygraph_core'
PYX_FILE = os.path.join(PROJECT_NAME, f"{CYTHON_MODULE_NAME}.pyx")
# ----------------------------------------

# Fix 1: Correctly read the long_description
this_directory = Path(__file__).parent
long_description = (this_directory / "README.md").read_text()

# Improvement 4: Handle compiler flags for cross-platform
extra_compile_args = []
if sys.platform == 'win32':
    extra_compile_args.extend(['/O2', '/openmp'])
elif sys.platform in ('linux', 'darwin'):
    extra_compile_args.extend(['-O3', '-fopenmp'])

extensions = [
    Extension(
        name=f"{PROJECT_NAME}.{CYTHON_MODULE_NAME}", 
        sources=[PYX_FILE],
        include_dirs=[numpy.get_include()],
        extra_compile_args=extra_compile_args
    )
]

setup(
    name=PROJECT_NAME, 
    version=VERSION,
    description='A high-performance 2D/3D graphics and multimedia framework built on Cython and OpenCV.',
    author='PyGraph developer(s)',
    url='https://github.com/TunnelMiner12/PyGraph',
    packages=[PROJECT_NAME], 
    
    # Fix 1: Pass long description and content type
    long_description=long_description,
    long_description_content_type='text/markdown',
    
    # Metadata for PyPI 
    license='MIT', 
    classifiers=[
        'Development Status :: 3 - Alpha',
        'Intended Audience :: Developers',
        'Intended Audience :: Science/Research',
        'License :: OSI Approved :: MIT License',
        'Programming Language :: Cython',
        'Programming Language :: Python :: 3',
        'Programming Language :: Python :: 3.8',
        'Programming Language :: Python :: 3.9',
        'Programming Language :: Python :: 3.10',
        'Programming Language :: Python :: 3.11',
        'Topic :: Multimedia :: Graphics',
        'Topic :: Software Development :: Libraries :: Python Modules',
    ],
    
    # Cython Compilation
    ext_modules=cythonize(extensions, language_level="3", annotate=True),
    
    # Dependencies (Runtime)
    install_requires=[
        'Pillow', 
        'numpy',
        'opencv-python',
    ],
    
    setup_requires=[
        'Cython',
        'numpy',
    ],
    
    package_data={
        PROJECT_NAME: [f"{CYTHON_MODULE_NAME}.pyx", "*.py"]
    },
    include_package_data=True
)