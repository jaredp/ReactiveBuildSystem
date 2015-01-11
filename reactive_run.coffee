{exec} = require 'child_process'
path = require 'path'
us = require 'underscore'

module.exports = (command, callback) ->
  # TODO separate strace output from command stderr, and pass stderr
  # back to caller

  exec "strace -f -v -qq -e trace=file -e signal=none bash -c '#{command}'",
    {maxBuffer: Infinity},
    (err, stdout, stderr) ->

      [dependancies, dependants] = [[], []]

      for line in stderr.split('\n')
        try
          [_, _, pid, line] = line.match(/^(\[pid\s+(\d+)\] )?(.*)$/)
          [_, syscall, args, retval] = line.match(/^(\w+)\((.*)\)\s*=\s*(.*)$/)

        catch
          # for debugging, report if we fail to parse
          console.error 'bad strace line', line if line
          continue

        try
          switch syscall
            when 'open', 'openat'
              if syscall == 'open'
                [fname, mode] = parse_strace_args args, [PATH, OPTS]

              if syscall == 'openat'
                [fromdir, fname, mode] = parse_strace_args args, [PRIMITIVE, PATH, OPTS]
                throw 'unimplemented' unless fromdir == 'AT_FDCWD'

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

            when 'stat'
              # TODO stat-ing a directory probably shouldn't make us rebuild when the
              # directory contents change
              [fname, stat] = parse_strace_args args, [PATH, EITHER([STRUCT, PRIMITIVE])]
              dependancies.push fname

            when 'execve'
              [fname, argv, env] = parse_strace_args args, [PATH, ARRAY, ARRAY]
              dependancies.push fname

            # TODO lstat

            # TODO access

            # TODO unlink

            else
              #console.log 'syscall', syscall, args, retval

        catch e
          # for debugging only; in prod, just ignore and continue
          console.error syscall, args
          throw e

      # clean up results
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

## Arg type parsers

STRING = (s) ->
  [token, val] = s.match(/^"(([^"]|\\")*)"/)
  # TODO we *should* do some escaping here
  return [token, val]

PATH = (s) ->
  [token, val] = STRING(s)
  # TODO this assumes the process hasn't chdir()ed
  # TODO this does not handle openat for non-AT_FDCWD
  # TODO we may not be in the same cwd as the project root
  [token, path.resolve(val)]

SWITCH = (s) -> s.match(/^([a-zA-Z0-9_$]*)/)

PRIMITIVE = (s) -> s.match(/^([a-zA-Z0-9_$]*)/)

# TODO we don't care about any struct members yet
STRUCT = (s) -> s.match(/^{(.*?)}/)

# TODO we don't care about any array members yet
ARRAY = (s) -> s.match(/^\[(.*?)\]/)

OPTS = (s) ->
  [token, opts] = s.match(/^([a-zA-Z0-9_$|]*)/)
  return [token, opts.split('|')]

EITHER = (opts) -> (s) ->
  for opt in opts
    try
      val = opt(s)
      return val if val?
    catch
      continue
  throw "failed"
