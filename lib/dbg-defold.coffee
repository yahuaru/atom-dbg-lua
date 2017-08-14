fs = require 'fs'
path = require 'path'
atomSocket = require 'atom-socket'
{BufferedProcess, CompositeDisposable, Emitter} = require 'atom'
net = require 'net'

escapePath = (path) ->
  return (path.replace /\\/g, '/').replace /[\s\t\n]/g, '\\ '

commandStatus =
  requestAccepted: '200'
  badRequest: '400'
  errorInExecution: '401'
  break: '202'
  watch: '203'
  output: '204'

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
  subscriptions: null
  outputPanel: null
  breakpoints: []
  ui: null
  interactiveSession: null
  showOutputPanel: false
  unseenOutputPanelContent: false
  closedNaturally: false
  miEmitter: null
  errorEncountered: null
  socket: null
  server: null
  variableRootObjects: {}
  requestQueue: []
  waitingResponse: false
  running: false

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

    @start options

    @miEmitter.on 'console', (line) =>
      if @outputPanel
        if @showOutputPanelNext
          @showOutputPanelNext = false
          @outputPanel.show()
        @outputPanel.print '\x1b[37;40m'+line.replace(/([^\r\n]+)\r?\n/,'\x1b[0K$1\r\n')+'\x1b[39;49m', false

    @miEmitter.on 'result', ({type, data}) =>
      switch type
        when 'run'
          @ui.running()


  cleanupFrame: ->
    @errorEncountered = null
    return new Promise (fulfill) =>
      @sendCommand 'delallw'
        .then =>
          @variableObjects = {}
          @variableRootObjects = {}

  start: (options) ->
    @ui.paused()
    @showOutputPanel = true
    @unseenOutputPanelContent = false
    @closedNaturally = false
    @outputPanel?.clear()

    matchAsyncHeader = /^([\^=*+])(.+?)(?:,(.*))?$/

    handleError = (message) =>
      atom.notifications.addError 'Error running Defold Debugger',
        description: message
        dismissable: true
      @ui.stop()

    if @outputPanel and @outputPanel.getInteractiveSession
      interactiveSession = @outputPanel.getInteractiveSession()
      if interactiveSession.pty
        @interactiveSession = interactiveSession

    if @interactiveSession
      @interactiveSession.pty.on 'data', (data) =>
        if @showOutputPanelNext
          @showOutputPanelNext = false
          @outputPanel.show()
        @unseenOutputPanelContent = true

    if @interactiveSession
      @interactiveSession.pty.on 'data', (data) =>
        if @showOutputPanelNext
          @showOutputPanelNext = false
          @outputPanel.show()
        @unseenOutputPanelContent = true

    @miEmitter = new Emitter()

    #Server
    @server = net.createServer (socket) =>
        @outputPanel.print 'CONNECTED: '+socket.remoteAddress+':'+socket.remotePort
        if @logToConsole then console.log 'CONNECTED:', socket.remoteAddress+':'+socket.remotePort
        @socket = socket

        for breakpoint in @breakpoints
          @addBreakpoint breakpoint

        @socket.on 'data' , (data) =>
          message = data.toString()
          if @logToConsole then console.log 'DATA', socket.remoteAddress+':'+socket.remotePort, message
          code = message.find(///[0-9+]///)
          switch code
            when commandStatus.requestAccepted
              if @requestQueue.length > 0
                request = @requestQueue.shift()
                @miEmitter.emit 'result', {type:request.command, data:request.args}
            when commandStatus.badRequest
              if @requestQueue.length > 0
                @requestQueue.shift()



        @socket.on 'close', (data) =>
          if @logToConsole then console.log 'CLOSED:', socket.remoteAddress+':'+socket.remotePort


    @outputPanel.print 'Run the program you wish to debug'
    @server.listen(8172, 'localhost');

    #Server end

    @waitingResponse = false
    @requestQueue = []

  stop: ->
    @errorEncountered = null
    @variableObjects = {}
    @variableRootObjects = {}

    @socket?.end()
    @socket?.destroy()
    @server?.close()
    @server = null
    @socket = null
    @waitingResponse = false
    @requestQueue = []

    if @interactiveSession
      @interactiveSession.discard()
      @interactiveSession = null

    if !@closedNaturally or !@unseenOutputPanelContent
      @outputPanel?.hide()

  continue: ->
    @sendCommand 'run'
      .catch (error) =>
        if typeof error != 'string' then return
        @handleMiError error

  pause: ->
    return

  selectFrame: ->
    return

  getVariableChildren: (name) -> return new Promise (fulfill) =>
    fulfill [
      name: ''
      type: ''
      value: ''
      expandable: false
    ]

  stepIn: ->
    @cleanupFrame().then =>
      @sendCommand 'step'
        .catch (error) =>
          if typeof error != 'string' then return
          @handleMiError error

  stepOut: ->
    @cleanupFrame().then =>
      @sendCommand 'out'
        .catch (error) =>
          if typeof error != 'string' then return
          @handleMiError error

  stepOver: ->
    @cleanupFrame().then =>
      @sendCommand 'over'
        .catch (error) =>
          if typeof error != 'string' then return
          @handleMiError error

  sendCommand: (command, args = '') ->
    @requestQueue.push => {command:command, args:args}
    if @logToConsole then console.log 'dbg-defold > ',command,' ', args
    @socket.write command.toUpperCase()+' '+args+'\n'

  addBreakpoint: (breakpoint) ->
    @breakpoints.push breakpoint

    path = '/'+atom.project.relativizePath(breakpoint.path)[1]
    @sendCommand 'setb', (escapePath path)+' '+breakpoint.line
      .catch (error) =>
        if typeof error != 'string' then return
        if error.match /no symbol table is loaded/i
          atom.notifications.addError 'Unable to use breakpoints',
            description: '\nBreakpoints cannot be used.'
            dismissable: true

  removeBreakpoint: (breakpoint) ->
    for i,compare in @breakpoints
      if compare==breakpoint
        @breakpoints.splice i,1

    path = '/'+atom.project.relativizePath(breakpoint.path)[1]
    @sendCommand 'delb', (escapePath path)+' '+breakpoint.line
      .catch (error) =>
        if typeof error != 'string' then return
        @handleMiError error


  provideDbgProvider: ->
    name: 'dbg-defold'
    description: "Defold debugger"

    canHandleOptions: (options) =>
      return new Promise(fulfill, reject) =>
        @start options
        .then =>
          @stop()
          fulfill true

        .catch (error) =>
          @stop()
          if typeof error == 'string' && error.match /not in executable format/
            fulfill false
          else
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
