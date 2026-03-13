class ToolFunction {
  final String name;
  final String? description;
  final Map<String, dynamic>? parameters;
  final bool? strict;

  const ToolFunction({
    required this.name,
    this.description,
    this.parameters,
    this.strict,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      if (description != null) 'description': description,
      if (parameters != null) 'parameters': parameters,
      if (strict != null) 'strict': strict,
    };
  }
}

class ToolDefinition {
  final String type;
  final ToolFunction? function;

  const ToolDefinition.function({required this.function})
    : type = 'function',
      assert(function != null);

  Map<String, dynamic> toJson() {
    return {'type': type, if (function != null) 'function': function!.toJson()};
  }
}

class ToolChoice {
  final String? mode;
  final String? functionName;

  const ToolChoice._({this.mode, this.functionName});

  const ToolChoice.none() : this._(mode: 'none');

  const ToolChoice.auto() : this._(mode: 'auto');

  const ToolChoice.required() : this._(mode: 'required');

  const ToolChoice.function(String functionName)
    : this._(functionName: functionName);

  dynamic toJson() {
    if (mode != null) {
      return mode;
    }
    return {
      'type': 'function',
      'function': {'name': functionName},
    };
  }
}

class ToolCallFunction {
  final String? name;
  final String arguments;

  const ToolCallFunction({this.name, this.arguments = ''});

  factory ToolCallFunction.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return ToolCallFunction(
      name: json['name'] as String?,
      arguments: json['arguments']?.toString() ?? '',
    );
  }

  ToolCallFunction copyWith({String? name, String? arguments}) {
    return ToolCallFunction(
      name: name ?? this.name,
      arguments: arguments ?? this.arguments,
    );
  }

  Map<String, dynamic> toJson() {
    return {if (name != null) 'name': name, 'arguments': arguments};
  }
}

class ToolCall {
  final int? index;
  final String? id;
  final String? type;
  final ToolCallFunction? function;

  const ToolCall({this.index, this.id, this.type, this.function});

  static int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  factory ToolCall.fromJson(dynamic data) {
    final json = data as Map<String, dynamic>;
    return ToolCall(
      index: _asInt(json['index']),
      id: json['id'] as String?,
      type: json['type'] as String?,
      function: json['function'] == null
          ? null
          : ToolCallFunction.fromJson(json['function']),
    );
  }

  ToolCall copyWith({
    int? index,
    String? id,
    String? type,
    ToolCallFunction? function,
  }) {
    return ToolCall(
      index: index ?? this.index,
      id: id ?? this.id,
      type: type ?? this.type,
      function: function ?? this.function,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (index != null) 'index': index,
      if (id != null) 'id': id,
      if (type != null) 'type': type,
      if (function != null) 'function': function!.toJson(),
    };
  }
}
