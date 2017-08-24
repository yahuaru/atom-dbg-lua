module.exports = (dump) ->
  CoffeeScript = require 'coffeescript'

  dump = dump.match(/{.*}/g)[0]
  dump = dump.split('function() --[[..skipped..]] end').join('"function() --[[..skipped..]] end"')
  dump = dump.replace name+'=', '"'+name+'"=' for name in dump.match(/\w+(?==)/g)
  dump = dump.split('nil').join('"nil"')
  for name in dump.match(/[a-zA-Z]+[0-9]*[a-zA-Z]*[,}]/g)
    dump = dump.replace name, '"function() --[[..skipped..]] end"'+ name.slice(name.length-1)
  dump = dump.replace '__dm_script_instance__', '"__dm_script_instance__"'
  dump = dump.split('{').join('[')
  dump = dump.split('}').join(']')
  dump = dump.split('=').join(':')
  code = CoffeeScript.compile(dump, bare: true)
  frames = eval(code)
  stack = []
  stack_variables = []
  filepath = ''
  for frame_info in frames
    call = frame_info[0]

    name = ''
    if call[4] == 'main' then name = 'main chunk'
    else if call[4] == "C"
      if call[0] != 'null' then name = call[0] else name = "C function"
    else if call[4] == "tail" then name = "tail call"
    else if call[0] != 'nil' then name = call[0] else name = "anonymous function"

    frame =
      name: name
      file: filepath + call[1]
      line: call[3]
      path: call[1]+":"+call[2]
    variables = []

    for var_info in frame_info[1]
      for key, value of var_info
        create_variable = (key, value) ->
          type = ''
          val = ''
          if typeof(value) == 'object' && Array.isArray(value)
            if typeof(value[0]) == 'string'
              if value[0] == value[1] then type = 'string' else type = value[0]
            else if typeof(value[0]) == 'object'
              type = 'table'
            else
              type = typeof(value[0])

            val = value[1]
          else
            if typeof(value) == 'string' && value == 'function() --[[..skipped..]] end'
              type = 'function'
            else
              type = typeof(value)
            val = value

          return variable =
            name: key
            type: type
            value: val
            local: true
            file: frame.file
            expandable: type == 'table'

        var_stack = []
        recursive_check = (key, value) =>
          var_stack.push key
          location = var_stack.join('.')
          if variables[location]
            var_stack.pop()
            return

          if typeof(value[0]) == 'object'
            if Array.isArray(value[0])
              for _key, _value of value[0][0]
                recursive_check(_key, _value)
            else
              for _key, _value of value[0]
                recursive_check(_key, _value)

          variables[location] = create_variable(key,value)
          var_stack.pop()

        recursive_check(key, value)
    stack.unshift frame
    stack_variables.unshift variables
  return {stack: stack, variables:stack_variables}
