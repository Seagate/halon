#!/usr/bin/env python3

import sys
import os

project = 'Halon'
copyright = '2015, Seagate Technology Limited'
author = 'Tweag I/O Limited'

# The short X.Y version.
version = '0.1'

# The full version, including alpha/beta/rc tags.
release = '0.1'

extensions = [
    'sphinx.ext.todo',
    'sphinx.ext.mathjax',
    'sphinx.ext.ifconfig',
]

templates_path = ['_templates']
source_suffix = ['.rst', '.md']
source_parsers = {
    '.md': 'recommonmark.parser.CommonMarkParser',
}
master_doc = 'index'
language = None
exclude_patterns = ['_build']

# If true, '()' will be appended to :func: etc. cross-reference text.
add_function_parentheses = False

# The name of the Pygments (syntax highlighting) style to use.
pygments_style = 'sphinx'

# If true, `todo` and `todoList` produce output, else they produce nothing.
todo_include_todos = True


# -- Options for HTML output ----------------------------------------------

html_theme = 'alabaster'
html_static_path = ['_static']
html_show_sphinx = False
htmlhelp_basename = 'Halondoc'

# -- Options for LaTeX output ---------------------------------------------

latex_elements = {
    'papersize': 'a4paper',
    'pointsize': '11pt',
    'figure_align': 'htbp',
}

# (source start file, target name, title,
#  author, documentclass [howto, manual, or own class]).
latex_documents = [
    (master_doc, 'Halon.tex', 'Halon Documentation', author, 'manual'),
]

# -- Options for manual page output ---------------------------------------

# (source start file, name, description, authors, manual section).
man_pages = [
    (master_doc, 'halonctl', 'Halon Documentation', [author], 1),
    (master_doc, 'halond', 'Halon Documentation', [author], 1),
]
