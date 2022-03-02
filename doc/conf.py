#!/usr/bin/env python3

import sys
import os

project = 'Halon'
copyright = '2015, Seagate Technology LLC and/or its Affiliates'
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
exclude_patterns = ['_build']
language = None

source_suffix = ['.rst', '.md']
source_parsers = {
    '.md': 'recommonmark.parser.CommonMarkParser',
}

master_doc = 'contents'

# If true, '()' will be appended to :func: etc. cross-reference text.
add_function_parentheses = False

# The name of the Pygments (syntax highlighting) style to use.
pygments_style = 'sphinx'

# If true, `todo` and `todoList` produce output, else they produce nothing.
todo_include_todos = True


# -- Options for HTML output ----------------------------------------------

html_theme = 'sphinx_rtd_theme'
html_additional_pages = {
    'index': 'index.html',
}
html_static_path = ['_static']
html_show_sphinx = False
htmlhelp_basename = 'Halondoc'

# -- Options for LaTeX output ---------------------------------------------

latex_elements = {
    'papersize': 'a4paper',
    'pointsize': '11pt',
    'figure_align': 'htbp',
    'inputenc': r'\usepackage[utf8x]{inputenc}',
    'utf8extra': '',
}

# (source start file, target name, title,
#  author, documentclass [howto, manual, or own class]).
latex_documents = [
    ('user/index', 'Halon.tex', 'Halon Documentation', author, 'user guide'),
]

# Sections to append as an appendix to all documents.
latex_appendices = ['glossary']

# -- Options for manual page output ---------------------------------------

# (source start file, name, description, authors, manual section).
man_pages = [
    ('man/halonctl', 'halonctl', 'Halon Documentation', [author], 1),
    ('man/halond', 'halond', 'Halon Documentation', [author], 1),
]
