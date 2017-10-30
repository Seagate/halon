Schema visualizer
=================

This script prepares an image that shows all possible relations
between Halon resources.

Usage:

0. Add import of instances from all modules in the project on the top
   of `mero-halon/scripts/visualize-schema/visualize.hs`.
1. Run the script:
```
scripts/visualize-schema > schema.dot
```
2. Convert DOT file into an image:
```
dot schema.dot -Tpng -o schema.png
```
