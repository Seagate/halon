Schema visualizer
=================

This script prepares an image that shows all possible relations
between Halon resources.

Usage:

0. Add import of instances from all modules in the project on the top
   of `mero-halon/scripts/visualize-schema/visualize.hs`.

1. Generate DOT file:
```bash
./run-visualize > schema.dot
```

2. Convert DOT file into an image:
```bash
dot schema.dot -Tpng -o schema.png
```

3. Alternatively, generate a HTML page which can be zoomed, moved, and
   text-searched in a browser.
```bash
./genhtml > schema.html
```
