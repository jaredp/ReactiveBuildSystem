fs = require 'fs'
path = require 'path'

us = require 'underscore'
async = require 'async'
subdir = require 'subdir'

project_root = process.cwd()

## Job management

jobs = []
dependant_jobs = (key) -> jobs.filter (j) -> j.depends_on(key)
is_produced = (key) -> us.any(jobs.filter (j) -> key in j.products)

run_job = (job, callback = (->)) ->
  # get the old products from the last run we may need to clean up
  oldproducts = job.products

  job.rerun ->
    # TODO don't delete files that were intentionally left unchanged
    # TODO don't propagate changes to files which ended up the same

    # delete stale files
    stale_keys = us.difference(oldproducts, job.products)
    delete_dead_key(stale_key) for stale_key in stale_keys

    # mark all freshly changed files as dirty to propagate their changes
    wrote_key(product) for product in job.products

    callback()

add_job = (job) ->
  jobs.push(job)
  queue_job(job)

## Key management

wrote_key = (key) ->
  # TODO if key of new file, dirty the file's directory
  dirty_key(key)

delete_dead_key = (key) ->
  file = file_for_key(key)
  #console.log 'deleting:', file
  fs.unlink file, ->
    # TODO dirty the directory
    dirty_key(key)

## File keys
# for now, all keys are file keys, and they are just relative paths
# to the root of the project

key_for_file = (file) ->
  return null unless subdir(project_root, file)
  return path.relative(project_root, file)

file_for_key = (key) ->
  # TODO strip fs:/
  return path.resolve(key)

## Rebuild policy
# For now, use a stupid policy of only run one job at a time.
# HACK keeps track of whether a job is in the queue as to not dup entries via
# job.is_queued, which shouldn't exist.

job_queue = async.queue ((task, callback)-> task(callback)), 1

dirty_key = (key) ->
  #console.log 'dirty:', key
  queue_job(job) for job in dependant_jobs(key)

queue_job = (job) ->
  # if job is already in the queue, don't add it again
  return if job.is_queued == true
  job.is_queued = true

  job_queue.push (callback) ->
    job.is_queued = false
    run_job job, ->
      #console.dir {cmd: job.cmd, deps: job.dependancies, prods: job.products}
      callback()


## Bash builder
reactive_run = require './reactive_run'

class BashBuilder
  constructor: (@cmd) ->
    # errors/warnings produced by the command, i.e. parsed stdout + stderr
    @notes = ''

    # deps/prods get filled in at first run
    @dependancies = []
    @products = []

    # @is_good is currently unused
    # it's unclear what it's inital value should be or represent
    @is_good = false

  rerun: (callback) ->
    console.log @cmd
    reactive_run @cmd, (results) =>
      #console.dir 'finished', @cmd, results
      console.log results.stdout if results.stdout

      # translate from file paths to keys
      # ignore system files outside the project
      @dependancies = us.compact(results.dependancies.map(key_for_file))
      @products = us.compact(results.dependants.map(key_for_file))

      #console.dir {cmd: @cmd, thedeps: @dependancies, prods: @products}

      @is_good = results.succeeded

      # TODO standardized, structured format for code annotations (i.e. line
      # and column numbers for errors)
      # TODO incorporate stderr
      @notes = results.stdout

      callback()

  depends_on: (key) ->
    return key in @dependancies


## front end

debounce_block = {}

fs.watch '.', (evt, filename) ->
  # so this is actually pretty sketchy since there's probs
  # no guarentee of ordering

  return if debounce_block[filename]
  debounce_block[filename] = true
  setTimeout (->
    #console.log 'changed:', filename
    filekey = key_for_file(path.resolve(filename))
    dirty_key(filekey) unless is_produced(filekey)
    delete debounce_block[filename]
  ), 100



## example buildfile

run = (cmd) ->
  job = new BashBuilder(cmd)
  add_job(job)

run 'coffee -c cs.coffee'
run 'coffee -c cas.coffee'

run 'gcc -c myprog.c'
run 'gcc -c support.c'
run 'gcc support.o myprog.o -o myproc'
run './myproc'
