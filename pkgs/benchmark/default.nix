{writers, ...}:
writers.writePython3Bin "benchmark" {} (builtins.readFile ./benchmark.py)
