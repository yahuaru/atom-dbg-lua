fs = require 'fs'
path = require 'path'
net = require 'net'
{BufferedProcess, CompositeDisposable, Emitter} = require 'atom'

escapePath = (filepath) ->
  return (filepath.replace /\\/g, '/').replace /[\s\t\n]/g, '\\ '

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
  variables: []
  frames:[]

  getFullStack: (stack) =>
    return new Promise (resolve, reject) ->
      output = ''
      script = path.resolve __dirname, './lua_stack.lua'
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
      @process.process.stdin.write escapePath(atom.project.getPaths()[0])+'\r\n', binary: true


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
    @frame = []
    @variables = []


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

        @sendCommand "basedir", [escapePath atom.project.getPaths()[0]]

        @socket.on 'data' , (data) =>
          response = data.toString()
          if @logToConsole then console.log 'DATA', socket.remoteAddress+':'+socket.remotePort, response
          messages = response.split '\n'
          for message in messages
            if message == "" or message == null then continue
            code = message.match(///^[0-9]+///g)[0]
            if @logToConsole then console.log 'code:',code
            switch code
              when commandStatus.requestAccepted
                request = @requestQueue.shift()
                switch request.command
                  when 'run'
                    @ui.running()
                  when 'stack'
                    @getFullStack(message)
                    .then (response) =>
                      if @logToConsole then console.log 'stack json: ', response
                      frames = response
                      frames = frames.reverse()
                      frame.file = frame.file.replace /\//g, '\\' for frame in frames
                      @ui.setStack(response)
                      Array::push.apply @variables, frame.variables for frame in frames
                      @ui.setVariables(@variables)
                      @ui.setFrame(frames.length - 1)
                      @ui.paused()
                    .catch (error) =>
                      if @logToConsole then console.error 'failed', error
              when commandStatus.badRequest
                if @requestQueue.length > 0
                  @requestQueue.shift()
              when commandStatus.break
                filepath = path.resolve escapePath(atom.project.getPaths()[0]), '.'+message.match(///((\/\w+)+\.\w+)///g)[0]
                line = message.match(///[0-9]+$///g)[0]
                @sendCommand 'stack'



        @socket.on 'close', (data) =>
          if @logToConsole then console.log 'CLOSED:', socket.remoteAddress+':'+socket.remotePort
          @ui.stop()


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
    @variables = []

    if @interactiveSession
      @interactiveSession.discard()
      @interactiveSession = null

    if !@closedNaturally or !@unseenOutputPanelContent
      @outputPanel?.hide()

  continue: ->
    @sendCommand 'run'

  pause: ->
    return

  selectFrame: (index) ->
    @cleanupFrame
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
    @sendCommand 'step'

  stepOut: ->
    @cleanupFrame()
    @sendCommand 'out'

  stepOver: ->
    @cleanupFrame()
    @sendCommand 'over'

  sendCommand: (command, args = ['']) ->
    @requestQueue.push {command:command, args:args}
    arg = args.join ' '
    if @logToConsole then console.log 'dbg-defold > ',command,' ', arg
    @socket.write command.toUpperCase()+' '+arg+'\n'

  addBreakpoint: (breakpoint) ->
    @breakpoints.push breakpoint

    filepath = '/'+escapePath(atom.project.relativizePath(breakpoint.path)[1])
    @sendCommand 'setb', [filepath, breakpoint.line]

  removeBreakpoint: (breakpoint) ->
    for i,compare in @breakpoints
      if compare==breakpoint
        @breakpoints.splice i,1

    filepath = '/'+escapePath(atom.project.relativizePath(breakpoint.path)[1])
    @sendCommand 'delb', [filepath, breakpoint.line]


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
