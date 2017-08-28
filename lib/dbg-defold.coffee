MobDebug = require './mobdebug'
fs = require 'fs'
path = require 'path'
net = require 'net'
{BufferedProcess, CompositeDisposable, Emitter} = require 'atom'


module.exports = DbgDefold =
  config:
    logToConsole:
      title: 'Log to developer console'
      description: 'For debugging Defold problems'
      type: 'boolean'
      default: true
  logToConsole: true
  dbg: null
  modalPanel: null
  outputPanel: null
  ui: null
  interactiveSession: null
  showOutputPanel: false
  unseenOutputPanelContent: false
  closedNaturally: false
  running: false
  breakpoints: []
  mdbg: new MobDebug()

  activate: (state) ->
    #require('atom-package-deps').install('dbg-defold')

    atom.config.observe 'dbg-defold.logToConsole', (set) =>
      @logToConsole = set

  consumeOutputPanel: (outputPanel) ->
    @outputPanel = outputPanel

  debug:(options, api) ->
    @ui = api.ui
    @breakpoints = api.breakpoints
    @outputPanel?.clear()

    @mdbg.emitter.on @mdbg.debugEvents.startedListen, (socket) =>
      @mdbg.addBreakpoint breakpoint for breakpoint in @breakpoints
    @mdbg.emitter.on @mdbg.debugEvents.requestAccepted, ({request, response}) =>
      switch request.command
        when @mdbg.commands.continue
          @ui.running()

    @start options

  cleanupFrame: ->
    @errorEncountered = null
    @frames = []
    @variables = []


  start: (options) ->
    @ui.paused()
    @showOutputPanel = true
    @unseenOutputPanelContent = false
    @outputPanel?.clear()

    if @outputPanel and @outputPanel.getInteractiveSession
      interactiveSession = @outputPanel.getInteractiveSession()
      if interactiveSession.pty then @interactiveSession = interactiveSession

    if @interactiveSession
      @interactiveSession.pty.on 'data', (data) =>
        if @showOutputPanelNext
          @showOutputPanelNext = false
          @outputPanel.show()
        @unseenOutputPanelContent = true

    @mdbg.start(options)

  stop: ->
    @mdbg.stop()
    @cleanupFrame()

    @breakpoints = []

    if @interactiveSession
      @interactiveSession.discard()
      @interactiveSession = null

    if !@closedNaturally or !@unseenOutputPanelContent
      @outputPanel?.hide()

  continue: ->
    @mdbg.sendCommand @mdbg.commands.continue

  pause: ->
    @mdbg.sendCommand @mdbg.commands.pause

  selectFrame: (index) ->
    @cleanupFrame()
    @ui.setFrame index

  getVariableChildren: (name) -> return new Promise (fulfill) =>
    var_path = name.split '.'
    vars = @variables
    empty_variable = [
      name: ''
      type: ''
      value: ''
      expandable: false
    ]
    for var_name in var_path
        variable = (i for i in vars when i.name is var_name)[0]
        vars = variable.children
    fulfill if variable.children then variable.children else []

  stepIn: ->
    @cleanupFrame()

  stepOut: ->
    @cleanupFrame()

  stepOver: ->
    @cleanupFrame()

  addBreakpoint: (breakpoint) ->
    if breakpoint in @breakpoints then return
    @breakpoints.push breakpoint
    filepath = '/'+escapePath(atom.project.relativizePath(breakpoint.path)[1])
    @sendCommand 'setb', [filepath, breakpoint.line]
    @emitter.emit 'addBreakpoint', breakpoint

  removeBreakpoint: (breakpoint) ->
    if breakpoint not in @breakpoints then return
    @breakpoints.splice(@breakpoints.indexOf(breakpoint), 1)
    filepath = '/'+escapePath(atom.project.relativizePath(breakpoint.path)[1])
    @sendCommand 'delb', [filepath, breakpoint.line]
    @emitter.emit 'removeBreakpoint', breakpoint


  provideDbgProvider: ->
    name: 'dbg-defold'
    description: "Defold debugger"

    canHandleOptions: (options) =>
      return new Promise(fulfill, reject) =>
            fulfill true

    debug: @debug.bind this
    stop: @stop.bind this

    continue: @continue.bind this
    pause: @pause.bind this

    selectFrame: @selectFrame.bind this
    getVariableChildren: @getVariableChildren.bind this

    stepIn: @stepIn.bind this
    stepOver: @stepOver.bind this
    stepOut: @stepOut.bind this

    addBreakpoint: @addBreakpoint.bind this
    removeBreakpoint: @removeBreakpoint.bind this

  consumeDbg: (dbg) ->
    @dbg = dbg
