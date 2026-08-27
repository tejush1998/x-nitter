import ../db_common


template dbFormatImpl*(formatstr: SqlQuery, dbQuote: proc (s: string): string {.nimcall.}, args: varargs[string]): string =
  var res = ""
  var a = 0
  let s = string(formatstr)
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '?':
      if i + 1 < s.len and s[i+1] == '?':
        # "??": escaped literal question mark (not a placeholder)
        add(res, '?')
        inc(i, 2)
        continue
      if a == args.len:
        dbError("""The number of "?" given exceeds the number of parameters present in the query.""")
      add(res, dbQuote(args[a]))
      inc(a)
      inc(i)
    else:
      add(res, c)
      inc(i)
  res
