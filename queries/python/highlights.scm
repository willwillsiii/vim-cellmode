;; extends

((comment) @cellDelim
  (#lua-match? @cellDelim "##"))

((comment) @cellDelim
  (#lua-match? @cellDelim "#%%%%"))

((comment) @cellDelim
  (#lua-match? @cellDelim "# %%%%"))
