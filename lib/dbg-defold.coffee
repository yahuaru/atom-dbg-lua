fs = require 'fs'
path = require 'path'
net = require 'net'
{BufferedProcess, CompositeDisposable, Emitter} = require 'atom'

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
  process: null

  getFullStack: (stack) =>
    return new Promise (resolve, reject) ->
      output = ''
      script = __dirname+'\\lua_stack.lua'
      @process = new BufferedProcess
        command: 'lua'
        args: [script]
        options:
          cwd: atom.project.getPaths()[0]
        stdout: (data) =>
          output += data
        stderr: (data) =>
          output += data
          reject output
        exit: (data) =>
          result = JSON.parse output
          resolve result

      @process.process.stdin.write stack+'\r\n', binary: true


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

        @sendCommand "basedir", [atom.project.getPaths()[0]]

        @socket.on 'data' , (data) =>
          response = data.toString()
          if @logToConsole then console.log 'DATA', socket.remoteAddress+':'+socket.remotePort, response
          messages = response.split '\n'
          for message in messages
            if message == "" or message == null then continue
            code = message.match(///^([0-9]+)///)[0]
            if @logToConsole then console.log 'code:',code
            switch code
              when commandStatus.requestAccepted
                request = @requestQueue.shift()
                switch request.command
                  when 'run'
                    @ui.running()
                  when 'stack'
                    @getFullStack(message)
                    .then (response) ->
                      result_stack = []
                      for func in response
                        result_stack.push
                          local: true
                          file: func.at_file
                          line: func.at_line
                          name: func.name
                          path: func.at_file
                          error: undefined
                    .catch (error) ->
                      console.error 'failed', error

              when commandStatus.badRequest
                if @requestQueue.length > 0
                  @requestQueue.shift()
              when commandStatus.break
                @sendCommand 'stack'



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

  stepOut: ->
    @cleanupFrame().then =>
      @sendCommand 'out'

  stepOver: ->
    @cleanupFrame().then =>
      @sendCommand 'over'

  sendCommand: (command, args = ['']) ->
    @requestQueue.push {command:command, args:args}
    arg = args.join ' '
    if @logToConsole then console.log 'dbg-defold > ',command,' ', arg
    @socket.write command.toUpperCase()+' '+arg+'\n'

  addBreakpoint: (breakpoint) ->
    @breakpoints.push breakpoint

    path = '/'+atom.project.relativizePath(breakpoint.path)[1]
    @sendCommand 'setb', [(escapePath path), breakpoint.line]

  removeBreakpoint: (breakpoint) ->
    for i,compare in @breakpoints
      if compare==breakpoint
        @breakpoints.splice i,1

    path = '/'+atom.project.relativizePath(breakpoint.path)[1]
    @sendCommand 'delb', [(escapePath path), breakpoint.line]


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
