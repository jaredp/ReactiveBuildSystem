{exec} = require 'child_process'
path = require 'path'
subdir = require 'subdir'
us = require 'underscore'

project_root = process.cwd()

module.exports = (command, callback) ->
  # TODO separate strace output from command stderr, and pass stderr
  # back to caller

  exec "strace -f -v -qq -e trace=file -e signal=none bash -c '#{command}'",
    {maxBuffer: Infinity},
    (err, stdout, stderr) ->

      [dependancies, dependants] = [[], []]

      for line in stderr.split('\n')
        try
          [_, _, pid, line] = line.match(/^(\[pid (\d+)\] )?(.*)$/)
          [_, syscall, args, retval] = line.match(/^(\w+)\((.*)\)\s*=\s*(.*)$/)

        catch
          # for debugging, report if we fail to parse
          #console.error 'bad strace line', line if line
          continue

        try
          if syscall == 'open'
            [fname, mode] = parse_strace_args args, [
              argty.STRING
              argty.OPTS
            ]

            fname = clean_path fname
            continue unless fname?

            #exists = (retval != '-1 ENOENT (No such file or directory)')
            #succeeded = retval.match(/^\d+$/)?

            is_read = true if 'O_RDONLY' in mode
            is_read = false if 'O_WRONLY' in mode
            is_read = false if 'O_RDWR' in mode and 'O_CREAT' in mode

            # if it's RW and we can't tell, guess it's a write
            is_read = false unless is_read?

            if is_read
              dependancies.push fname

            else
              dependants.push fname

          # TODO openat AT_FDCWD

          if syscall == 'stat'
            [fname, stat] = parse_strace_args args, [
              argty.STRING
              argty.EITHER([argty.STRUCT, argty.PRIMITIVE])
            ]

            fname = clean_path fname
            continue unless fname?

            dependancies.push fname

          # TODO lstat

          # TODO access

          # TODO unlink

          if syscall == 'execve'
            [fname, argv, env] = parse_strace_args args, [
              argty.STRING
              argty.ARRAY
              argty.ARRAY
            ]

            fname = clean_path fname
            continue unless fname?

            dependancies.push fname


          else
            #console.log 'syscall', syscall, args, retval

        catch e
          console.error args
          throw e

      [dependancies, dependants] = [us.uniq(dependancies), us.uniq(dependants)]

      # if something appears in dependancies and dependants, we probably checked
      # it before writing it, so it's a dependant, since we don't allow cycles
      # or statefulness.
      dependancies = us.difference(dependancies, dependants)

      callback {
        dependancies, dependants, stdout
        succeeded: not err?
      }

parse_strace_args = (remaining, tys) ->
  try
    for ty in tys
      [token, val] = ty(remaining)
      remaining = remaining.slice(token.length)
      remaining = remaining.match(/^, (.*)$/)[1] if remaining
      val # return array of values returned from tys
  catch
    return null

argty =
  STRING: (s) ->
    [token, val] = s.match(/^"(([^"]|\\")*)"/)
    # TODO we *should* do some escaping here
    return [token, val]

  SWITCH: (s) -> s.match(/^([a-zA-Z0-9_$]*)/)

  PRIMITIVE: (s) -> s.match(/^([a-zA-Z0-9_$]*)/)

  # TODO we don't care about any struct members yet
  STRUCT: (s) -> s.match(/^{(.*?)}/)

  # TODO we don't care about any array members yet
  ARRAY: (s) -> s.match(/^\[(.*?)\]/)

  OPTS: (s) ->
    [token, opts] = s.match(/^([a-zA-Z0-9_$|]*)/)
    return [token, opts.split('|')]

  EITHER: (opts) -> (s) ->
    for opt in opts
      try
        val = opt(s)
        return val if val?
      catch
        continue
    throw "failed"


clean_path = (fname) ->
  # TODO this assumes the process hasn't chdir()ed
  # TODO this does not handle openat for non-AT_FDCWD
  # TODO we may not be in the same cwd as the project root
  fname = path.resolve(fname)
  return null unless subdir(project_root, fname)
  fname = path.relative(project_root, fname)
  return fname
