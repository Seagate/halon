Schema visualizer
==================

This script prepare an image that shows all possible
relations between resources in the project.

Usage:
0. add import of instances from all modules in the
   project on the top of the script.
1. enter project sandbox. From a toplevel directory
   call:
  cabal exec sh
2. run script:
  run-visualize > schema.dot
3. convert script to image:
  dot schema.dot -Tpng -o schema.png
