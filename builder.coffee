fs = require 'fs'
us = require 'underscore'

reactive_run = require './reactive_run'

changed_buffer = []
debounce_block = {}

active_jobs = 0
is_sleeping = -> active_jobs == 0

deps = {}

run = (cmd, cont = (->)) ->
  active_jobs += 1

  console.log cmd
  reactive_run cmd, (res) ->
    console.dir res
    console.log res.stdout if res.stdout

    olddeps = deps[cmd]
    deps[cmd] = res

    # delete stale files
    # TODO don't delete files that were intentionally left unchanged
    # TODO don't propagate changes to files which ended up the same

    if olddeps
      for stale_file in us.difference(olddeps.dependants, res.dependants)
        console.log 'deleting', file
        fs.unlink file, ->
          changed(file)

    for fresh_file in res.dependants
      propagate_changes(fresh_file)

    active_jobs -= 1
    changed_buffer = us.difference(changed_buffer, res.dependants)
    cont()
    check_changed()

propagate_changes = (filename) ->
  #console.log 'propagate', filename, deps
  for own cmd, details of deps
    if filename in details.dependancies
      run(cmd)

fs.watch '.', (evt, filename) ->
  # so this is actually pretty sketchy since there's probs
  # no guarentee of ordering

  setTimeout (->

    return if debounce_block[filename]
    debounce_block[filename] = true
    setTimeout (-> delete debounce_block[filename]), 100

    changed_buffer.push filename
    check_changed()

  ), 100

check_changed = ->
  return unless is_sleeping()
  [changed_files, changed_buffer] = [us.uniq(changed_buffer), []]

  for file in changed_files
    console.log file
    propagate_changes(file)

run 'coffee -c cs.coffee'
run 'coffee -c cas.coffee'

run 'gcc -c myprog.c', ->
  run 'gcc -c support.c', ->
    run 'gcc support.o myprog.o -o myproc', ->
      run './myproc'
