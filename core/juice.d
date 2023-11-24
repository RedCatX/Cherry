module core.juice;

import std.algorithm;
import std.exception;
import std.range;
import std.traits;
import std.ascii : isAlpha, isAlphaNum, isDigit, isHexDigit, toUpper, toLower;
import std.typecons;
import std.conv : text;

enum dchar[string] NamedCharacterEntities = 
[
    "quot": '\&quot;',
    "amp":  '\&amp;',
    "lt":   '\&lt;',
    "gt":   '\&gt;'
];

class JUICEException : Exception
{
    this(string file, uint line, string message) pure nothrow @safe
    {
        if (line)
            super(text(file, '(', line, "): ", message));
        else
            super(text(file, ": ", message));
    }
}

enum Operator : uint
{
    nop = 0,
    objectName,
    ternaryIf,
    ternaryElse,
    or,
    and,
    xor,
    bitwiseAnd,
    bitwiseOr,
    equal,
    notEqual,
    less,
    lessOrEqual,
    greater,
    greaterOrEqual,
    unordered,
    unorderedOrEqual,
    lessOrGreater,
    lessGreaterOrEqual,
    unorderedLessOrEqual,
    unorderedOrLess,
    unorderedGreaterOrEqual,
    unorderedOrGreater,
    leftShift,
    rightShift,
    unsignedRightShift,
    add,
    sub,
    concat,
    mul,
    div,
    mod,
    unaryPlus,
    unaryMinus,
    not
}

static immutable string[35] Operators = ["", "=>", "?", ":", "||", "&&", "^", "&", "|", "==", "!=", "<", "<=", 
                                         ">", ">=", "!<>=", "!<>", "<>", "<>=", "!>", "!>=", "!<", "!<=", 
                                         "<<", ">>", ">>>", "+", "-", "~", "*", "/", "%", "+", "-", "!"];

struct ValueToken 
{
    enum Type 
    {
        undefined,
        integerLiteral,
        floatLiteral,
        stringLiteral,
        operator,
        identifier,
        binding,
        doubleBinding,
        expressionBinding,
        expression,
        _true,
        _false,
        _null
    }

    union Store
    {
        long         _int;
        real         _real;
        string       _string;
        ValueToken[] _list;
    }

    this(string file, uint line, Type type, string text = null)
    {
        _file = file;
        _line = line;
        _type = type;

        if (type == Type.identifier ||
            type == Type.binding ||
            type == Type.doubleBinding)
        {
            _data._string = text;
        }
        else 
            _text = text;
    }

    this(string file, uint line, Operator op)
    {
        this(file, line, Type.operator);
        _data._int = op;
    }

    this(string file, uint line, string text, long value)
    {
        this(file, line, Type.integerLiteral, text);
        _data._int = value;
    }

    this(string file, uint line, string text, real value)
    {
        this(file, line, Type.floatLiteral, text);
        _data._real = value;
    }

    this(string file, uint line, string text, string value)
    {
        this(file, line, Type.stringLiteral, text);
        _data._string = value;
    }

    this(string file, uint line, ValueToken[] expression)
    {
        this(file, line, Type.expression);
        _data._list = expression;
    }

    T get(T)() const
    {
        static if (is(T == byte)  || is(T == ubyte)  ||
                   is(T == short) || is(T == ushort) ||
                   is(T == int)   || is(T == uint)   ||
                   is(T == long)  || is(T == ulong))
        {
            import std.traits : Signed, Unsigned;

            if (_type == Type.integerLiteral &&
                _data._int >= (Signed!T).min && 
                _data._int <= (Unsigned!T).max)
            {
                return cast(T)(_data._int);
            }
            else if (_type == Type._true)
            {
                return 1;
            }
            else if (_type == Type._false ||
                     _type == Type._null)
            {
                return 0;
            }
            else
                conversionError(typeid(T).toString);

            return 0;
        }
        else static if (is(T == char)  ||
                        is(T == wchar) ||
                        is(T == dchar))
        {
            if (_type == Type.integerLiteral &&
                _data._int >= T.min &&
                _data._int <= T.max)
            {
                return cast(T)(_data._int);
            }
            else if (_type == Type._true)
            {
                return 1;
            }
            else if (_type == Type._false ||
                     _type == Type._null)
            {
                return 0;
            }
            else
                conversionError(typeid(T).toString);

            return '\0';
        }
        else static if (is(T == double) || 
                        is(T == float) || 
                        is(T == real))
        {
            if (_type == Type.integerLiteral)
            {
                return _data._int;
            }
            else if (_type == Type.floatLiteral)
            {
                return _data._real;
            }
            else if (_type == Type._true)
            {
                return 1;
            }
            else if (_type == Type._false ||
                     _type == Type._null)
            {
                return 0;
            }
            else
                conversionError(typeid(T).toString);

            return 0;
        }
        else static if (is(T == string))
        {
            if (_type == Type.stringLiteral ||
                _type == Type.identifier ||
                _type == Type.doubleBinding ||
                _type == Type.binding)
            {
                return _data._string;
            }
            else if (_type == Type._null)
            {
                return null;
            }
            else
                conversionError("string");

            return null;
        }
        else static if (is(T == bool))
        {
            if (_type == Type._true ||
                _type == Type._false)
            {
                return (_type == Type._true);
            }
            else if (_type == Type.integerLiteral)
            {
                return _data._int != 0;
            }
            else if (_type == Type.floatLiteral)
            {
                return _data._real != 0;
            }
            else
                conversionError("bool");

            return false;
        }
        else static if (is(T == Operator))
        {
            if (_type == Type.operator &&
                _data._int >= Operator.nop &&
                _data._int <= Operator.not)
            {
                return cast(Operator)(_data._int);
            }
            else
                conversionError("Operator");

            return Operator.nop;
        }
    }

    @property const(ValueToken[]) expression() const
    {
        assert(_type == Type.expression || _type == Type.expressionBinding);
        return _data._list;
    }

    void addToExpr(ValueToken part)
    in {
        assert(_type == Type.expression || _type == Type.expressionBinding);
        assert(part._type != Type.expression);
        assert(part._type != Type.expressionBinding);
        assert(part._type != Type.doubleBinding);
        assert(part._type != Type.binding);
        assert(part._type != Type.undefined);
    }
    do {
        if (part._type == Type.operator &&
            _data._list.length > 0)
        {
            if (part._data._int == Operator.unaryMinus)
            {
                if (_data._list.back._type == Type.integerLiteral)
                {
                    if (_data._list.back._data._int >= 0)
                        _data._list.back._data._int = -(_data._list.back._data._int);
                    else
                    {
                        _data._list.back._type = Type.floatLiteral;
                        _data._list.back._data._real = -cast(ulong)(_data._list.back._data._int);                        
                    }

                    return;
                }
                else if (_data._list.back._type == Type.floatLiteral)
                {
                    _data._list.back._data._real = -(_data._list.back._data._real);
                    return;
                }
            }
            else if (part._data._int == Operator.not)
            {
                if (_data._list.back._type == Type.integerLiteral)
                {
                    _data._list.back._data._int = !_data._list.back._data._int;
                    return;
                }
                else if (_data._list.back._type == Type.floatLiteral)
                {
                    _data._list.back._data._real = !_data._list.back._data._real;
                    return;
                }
            }
            else if (part._data._int == Operator.unaryPlus)
            {
                return;
            }
        }
        
        _data._list ~= part;
    }

    @property string file() const pure @safe nothrow 
    {
        return _file;
    }

    @property uint line() const pure @safe nothrow 
    {
        return _line;
    }

    @property string text() const pure nothrow 
    {
        switch (_type)
        {
            case Type._true:
                return "true";

            case Type._false:
                return "false";

            case Type._null:
                return "null";

            case Type.identifier:
            case Type.binding:
            case Type.doubleBinding:
                return _data._string;

            case Type.operator:
                return Operators[cast(Operator)(_data._int)];

            default:
                return _text;
        }
    }

    @property void text(string value) pure nothrow 
    {
        _text = value;
    }

    @property Type type() const pure @safe nothrow 
    {
        return _type;
    }

private:
    uint   _line;
    string _file;
    string _text;
    Store  _data;
    Type   _type;

    void conversionError(string type) const
    {
        throw new JUICEException(_file, _line, "cannot implicitly convert this value to " ~ type);
    }
}

unittest 
{
    import std.math : round;

    // stringLiteral value test
    ValueToken v = ValueToken(__FILE__, __LINE__, "1000", 1000);
    assert(v.text == "1000");
    assert(v.type == ValueToken.Type.integerLiteral);
    assert(v.get!int == 1000);
    assert(round(v.get!double) == 1000);
    assertThrown!JUICEException(v.get!byte);

    // Double value test
    v = ValueToken(__FILE__, __LINE__, "25.5", 25.5);
    assert(v.type == ValueToken.Type.floatLiteral);
    assert(v.get!double == 25.5);
    assertThrown!JUICEException(v.get!string);

    // stringLiteral value test
    v = ValueToken(__FILE__, __LINE__, `"Hello"`, "Hello");
    assert(v.text == `"Hello"`);
    assert(v.type == ValueToken.Type.stringLiteral);
    assert(v.get!string == "Hello");
    assertThrown!JUICEException(v.get!bool);

    // characterLiteral value test
    v = ValueToken(__FILE__, __LINE__, `'\U0001F632'`, '\U0001F632');
    assert(v.text == `'\U0001F632'`);
    assert(v.type == ValueToken.Type.integerLiteral);
    assert(v.get!dchar == '\U0001F632');
    assertThrown!JUICEException(v.get!char);

    // Bool value test
    v = ValueToken(__FILE__, __LINE__, ValueToken.Type._true);
    assert(v.text == "true");
    assert(v.get!bool == true);
    assert(v.get!int == 1);
    v = ValueToken(__FILE__, __LINE__, ValueToken.Type._false);
    assert(v.get!bool == false);
}

enum ParserEvent 
{
    ready,
    startObject,
    endObject,
    startVersionBlock,
    endVersionBlock,
    property,
    key,
    value,
    startArray,
    endArray,
    end
}

/*

Cherry.UI.Form => Form1 {
    Title: "Form1",
    Width: 640,
    Height: 480,
    Content: Cherry.Panels.Canvas => Canvas1 {
        Controls: [
            Cherry.UI.Button => Button1 {
                Left: 46,
                Top: 24,
                Content: "Button",
                Default: true
            },
            Cherry.UI.TextBox => TextBox1 {
                Top: 24,
                Left: 81,
                Multiline: true,
                Text: "TextBox",
                Font: {
                    Face: "Comic Sans",
                    Weight: FontWeight.bolder,
                    Size: 24
                }
            },
            Cherry.UI.Rectangle => Rectangle1 {
                Left: 46,
                Top: 54,
                Width: 100,
                Height: 100
            }
        ]
    }
}

*/

struct Parser(T) 
{
    @disable this();

    this(string text, uint line, string file)
    {
        _line = line;
        _file = file;
        _text = text;
        _evt = ParserEvent.ready;
    }

    void next()
    {
        Node.Type type;

        bool isObject() { return _stack.back().type == Node.Type.object; } 
        bool isProperty() { return _stack.back().type == Node.Type.property; }
        bool isArray() { return _stack.back().type == Node.Type.array; }
        bool isDictionary() { return _stack.back().type == Node.Type.dictionary; }

        final switch (_evt) 
        {
            case ParserEvent.ready:
                skipWhitespace();
                if (_text.empty)
                    _evt = ParserEvent.end;
                else
                    doModule();
                break;

            case ParserEvent.startVersionBlock:
            case ParserEvent.startObject:
                if (testToken(Token.Type.rightBrace)) 
                {
                    _evt = ParserEvent.endObject;
                    _leftBraceCount--;
                }
                else
                    doProperty();
                break;

            case ParserEvent.property:
                _value = ValueToken();
                doPropertyValue();
                break;

            case ParserEvent.key:
                _value = ValueToken();
                doValue();
                break;
            
            case ParserEvent.value:
            case ParserEvent.endVersionBlock:
            case ParserEvent.endObject:
            case ParserEvent.endArray:
                type = _stack.back().type;
                if (isArray() ||
                    isDictionary())
                {
                    if (testToken(Token.Type.comma))
                    {
                        _value = ValueToken();
                        doValue();

                        if (type == Node.Type.dictionary)
                        {
                            if (_evt == ParserEvent.value)
                            {
                                _evt = ParserEvent.key;
                            }
                            else
                                doError("Expression expected but found object definition");

                            checkToken(Token.Type.colon);
                        }
                    }
                    else 
                    {
                        checkToken(Token.Type.rightSquareBracket);
                        _stack.popBack();
                        _evt = ParserEvent.endArray;
                    }
                }
                else
                {
                    _stack.popBack();
                    if (_stack.empty())
                        _evt = ParserEvent.end;
                    else
                    {
                        if (isProperty())
                            _stack.popBack();

                        if (testToken(Token.Type.comma) || 
                            type == Node.Type.versionBlock) 
                        {
                            if (testToken(Token.Type.rightBrace))
                            {
                                _evt = isObject() 
                                    ? ParserEvent.endObject 
                                    : ParserEvent.endVersionBlock;

                                _leftBraceCount--;
                            }
                            else if (testToken(Token.Type.rightSquareBracket))
                            {
                                if (isArray() || 
                                    isDictionary())
                                {
                                    _stack.popBack();
                                    _evt = ParserEvent.endArray;
                                }
                                else
                                    expected(peekToken().line, "`}`", "`]`");
                            }
                            else 
                            {
                                if (isArray())
                                {
                                    _value = ValueToken();
                                    doValue();
                                }
                                else if (isDictionary())
                                {
                                    _value = ValueToken();
                                    doExpression();
                                    checkToken(Token.Type.colon);
                                    _evt = ParserEvent.key;
                                }
                                else
                                    doProperty();
                            }
                        }
                        else if (testToken(Token.Type.rightBrace))
                        {
                            _evt = isObject() 
                                ? ParserEvent.endObject 
                                : ParserEvent.endVersionBlock;

                            _leftBraceCount--;
                        }
                        else if (testToken(Token.Type.rightSquareBracket))
                        {
                            if (isArray() ||
                                isDictionary())
                            {
                                _stack.popBack();
                                _evt = ParserEvent.endArray;
                            }
                            else
                                expected(peekToken().line, "`}`", "`]`");
                        }
                        else if (_text.empty && _leftBraceCount == 0)
                        {
                            _evt = ParserEvent.endObject;
                        }
                        else
                            expected(peekToken().line, isObject() ? "`}`" : "`]`"); 
                    } 
                }
                break;

            case ParserEvent.startArray:
                doValue();
                if (testToken(Token.Type.colon)) 
                {
                    if (_evt == ParserEvent.value)
                    {
                        _evt = ParserEvent.key;
                        _stack.back().type = Node.Type.dictionary;
                    }
                    else
                        expected(peekToken().line, "`,`");
                }
                break;

            case ParserEvent.end:
                break;
        }
    }

    @property ParserEvent event() const pure @safe nothrow 
    {
        return _evt;
    }

    @property string objectName() const pure @safe nothrow 
    {
        return findLastNodeByType(Node.Type.object).first;
    }

    @property string objectType() const pure @safe nothrow 
    {
        return findLastNodeByType(Node.Type.object).second;
    }

    @property string versionStr() const pure @safe nothrow 
    {
        return findLastNodeByType(Node.Type.versionBlock).first;
    }

    @property string property() const pure @safe nothrow
    {
        return findLastNodeByType(Node.Type.property).first;
    }

    @property const(ValueToken) value() const pure @safe nothrow
    {
        return _value;
    }

private:
    static if (is(T : const(char)[]))
        alias Char = char;
    else
        alias Char = Unqual!(ElementType!T);

    void doError(string msg)
    {
        throw new JUICEException(_file, _line, msg);
    }

    void expected(uint line, string e, string found = null)
    {
        string msg = "Expected " ~ e;
        if (found != null)
            msg ~= text(" but ", found, " found.");

        throw new JUICEException(_file, line, msg);
    }

    bool isWhite(dchar c)
    {
        import std.ascii : isWhite;
        return c == 0 || isWhite(c);
    }

    Char popChar()
    {
        if (_text.empty) doError("Unexpected end of data.");
        static if (is(T : const(char)[]))
        {
            Char c = _text[0];
            _text = _text[1..$];
        }
        else
        {
            Char c = _text.front;
            _text.popFront();
        }

        if (c == '\n')
        {
            _line++;
        }

        return c;
    }

    Char peekChar()
    {
        if (_nextCh.isNull)
        {
            if (_text.empty) return '\0';
            _nextCh = popChar();
        }
        return _nextCh.get;
    }

    Nullable!Char peekCharNullable()
    {
        if (_nextCh.isNull && !_text.empty)
        {
            _nextCh = popChar();
        }
        return _nextCh;
    }

    void skipWhitespace()
    {
        while (true)
        {
            auto c = peekCharNullable();

            if (c == '/' && !_text.empty())
            {
                static if (is(T : const(char)[]))
                {
                    Char next = _text[0];
                }
                else
                {
                    Char next = _text.front;
                }

                if (next == '/')
                {
                    while (!c.isNull && c != '\n')
                    {
                        _nextCh.nullify();
                        c = peekCharNullable();
                    }
                }
                else if (next == '*')
                {
                    Char prev = 0;
                    int commentStart = _line;

                    _nextCh.nullify();
                    c = peekCharNullable();

                    while (!c.isNull && (prev != '*' || c.get() != '/'))
                    {
                        if (prev == 0)
                            prev = '/';
                        else
                            prev = c.get();

                        _nextCh.nullify();
                        c = peekCharNullable();
                    }

                    if (!c.isNull)
                    {
                        _nextCh.nullify();
                        c = peekCharNullable();
                    } 
                    else
                        throw new JUICEException(_file, commentStart, "unterminated /* */ comment");
                }
            }

            if (c.isNull ||
                !isWhite(c.get))
            {
                return;
            }
            _nextCh.nullify();
        }
    }

    Char getChar(bool SkipWhitespace = false)()
    {
        static if (SkipWhitespace) skipWhitespace();

        if (!_nextCh.isNull)
        {
            _curCh = _nextCh.get;
            _nextCh.nullify();
        }
        else
            _curCh = popChar();

        return _curCh.get;
    }

    Char curCh()
    {
        if (_curCh.isNull)
            return getChar();

        return _curCh.get;
    }

    void checkChar(bool SkipWhitespace = true)(char c, bool caseSensitive = true)
    {
        static if (SkipWhitespace) skipWhitespace();
        auto c2 = getChar();
        if (!caseSensitive) c2 = toLower(c2);

        if (c2 != c) 
            throw new JUICEException(_file, _line, text("Expected `", c, "`."));
    }

    bool testChar(bool SkipWhitespace = true, bool CaseSensitive = true)(char c)
    {
        static if (SkipWhitespace) skipWhitespace();
        auto c2 = peekChar();
        static if (!CaseSensitive) c2 = toLower(c2);

        if (c2 != c) return false;

        getChar();
        return true;
    }

    Token getToken()
    {
        uint line = _line;
        auto ch = getChar!true();
        auto next = peekChar();

        // Skip comments
        if (ch == '/')
        {
            if (next == '/')
            {
                while (ch != '\n')
                {
                    ch = getChar();
                    next = peekChar();
                    if (next == '\0')
                        break;
                }

                skipWhitespace();
                if (peekChar() == '\0')
                    return Token(Token.Type.eof, _line);

                ch = getChar();
                next = peekChar();
                line = _line;
            }
            else if (next == '*')
            {
                getChar();
                while (ch != '*' || next != '/')
                {
                    ch = getChar();
                    next = peekChar();
                    if (next == '\0')
                        throw new JUICEException(_file, line, "unterminated /* */ comment");
                }

                getChar();
                skipWhitespace();
                if (peekChar() == '\0')
                    return Token(Token.Type.eof, _line);

                ch = getChar();
                next = peekChar();
                line = _line;
            }
        }

        // String
        if (ch == '"' || ch == '`' || ch == '\'' ||
            ((ch == 'r' || ch == 'q') && next == '"'))
        {
            return Token(doString());
        }

        // Number
        else if (isDigit(ch) || ch == '.')
        {
            return Token(doNumber());
        }

        // Identifier
        else if (isAlpha(ch) || ch == '_')
        {
            string id = doIdentifier();

            switch (id)
            {
                case "version":
                    return Token(Token.Type.ver, line);

                case "true":
                    return Token(ValueToken(_file, line, ValueToken.Type._true));

                case "false":
                    return Token(ValueToken(_file, line, ValueToken.Type._false));

                case "null":
                    return Token(ValueToken(_file, line, ValueToken.Type._null));

                default:
                    return Token(id, line);
            }
        }

        // Operator
        else
        {
            Operator op;

            switch (ch)
            {
                case ':':
                    return Token(Token.Type.colon, line);

                case ',':
                    return Token(Token.Type.comma, line);

                case '{':
                    return Token(Token.Type.leftBrace, line);

                case '}':
                    return Token(Token.Type.rightBrace, line);

                case '[':
                    return Token(Token.Type.leftSquareBracket, line);

                case ']':
                    return Token(Token.Type.rightSquareBracket, line);

                case '(':
                    return Token(Token.Type.leftBracket, line);

                case ')':
                    return Token(Token.Type.rightBracket, line);

                case '@':
                    if (next == '@')
                    {
                        getChar();
                        return Token(Token.Type.doubleBinding, line);
                    }
                    return Token(Token.Type.binding, line);

                default:
                    op = doOperator();
                    if (op == Operator.objectName)
                        return Token(Token.Type.objectName, line);
                    
                    return Token(op, line);
            }
        }

        return Token();
    }

    ValueToken doString()
    {
        dchar characterLiteral;
        string stringLiteral, raw;

        dchar doEscapeSequence()
        {
            string escape = "\\";
            dchar ch;
            ubyte i, sz;

            int hexDigitToNum(Char digit)
            {
                if (digit >= '0' && digit <= '9') 
                    return digit - '0';

                return toLower(digit) - 'a' + 10;
            }

            escape ~= getChar();
            switch (curCh)
            {
                case '\'':
                case '\"':
                case '\\':
                case '\?':
                    ch = curCh;
                    break;

                case '0':
                    ch = '\0';
                    break;
                case 'a':
                    ch = '\a';
                    break;
                case 'b':
                    ch = '\b';
                    break;
                case 'f':
                    ch = '\f';
                    break;
                case 'n':
                    ch = '\n';
                    break;
                case 'r':
                    ch = '\r';
                    break;
                case 't':
                    ch = '\t';
                    break;
                case 'v':
                    ch = '\v';
                    break;

                case '1': .. case '7':
                    uint val = (curCh - '0');
                    if (peekChar() >= '0' && peekChar() <= '7')
                    {
                        escape ~= getChar();
                        val = val * 8 + (curCh - '0');
                        if (peekChar() >= '0' && peekChar() <= '7')
                        {
                            escape ~= getChar();
                            val = val * 8 + (curCh - '0'); 
                        }
                    }
                    ch = val;
                    break;

                case 'x':
                    sz = 2;
                    goto case;
                case 'u':
                    if (sz == 0) 
                        sz = 4;
                    goto case;
                case 'U': 
                    if (sz == 0) 
                        sz = 8;
                    if ( isHexDigit(peekChar()) )
                    {
                        uint val = 0;

                        for (i = 1; i <= sz; i++)
                        {
                            escape ~= getChar();
                            val = val * 16 + hexDigitToNum(curCh);
                            if ( !isHexDigit(peekChar()) && i < sz)
                                doError(text("Escape hex sequence has ", i, " hex digits instead of ", sz));
                        }
                        ch = val;
                    }
                    else
                        doError(text("Undefined escape hex sequence ", escape, peekChar()));
                    break;

                case '&':
                    if (isAlpha(peekChar()) || peekChar() == '_') 
                    {
                        string entity = doIdentifier();

                        escape ~= entity;
                        if (testChar!(false)(';'))
                        {
                            escape ~= ';';
                            if (entity in NamedCharacterEntities)
                                ch = NamedCharacterEntities[entity];
                            else
                                doError(text("Unnamed character entity ", escape));
                        }
                        else
                            doError(text("Unterminated named entity ", escape));
                    }
                    break;

                default:
                    doError(text("Undefined escape sequence \\", curCh)); 
                    break;
            }

            raw ~= escape;
            stringLiteral ~= ch;
            return ch;
        }

        raw ~= curCh;

        switch (curCh) 
        {
            case '"':
                getChar();

                while (curCh != '"') 
                {
                    if (curCh == '\\')
                    {
                        doEscapeSequence();
                    }
                    else
                    {
                        stringLiteral ~= curCh;
                        raw ~= curCh;
                    }
                    getChar();
                }

                raw ~= curCh;
                break;

            case '`': 
                getChar();

                while (curCh != '`') 
                {
                    stringLiteral ~= curCh;
                    raw ~= curCh;
                    getChar();
                }

                raw ~= curCh;
                break;

            case 'r':
                raw ~= getChar();

                while (peekChar() != '"')
                {
                    raw ~= getChar();
                    stringLiteral ~= curCh;
                }

                raw ~= getChar();
                break;

            case 'q':
                break;

            case '\'':
                if (getChar() == '\\')
                {
                    characterLiteral = doEscapeSequence();
                }
                else
                {
                    raw ~= curCh;
                    characterLiteral = curCh;
                }

                checkChar!(false)('\'');
                raw ~= '\'';
                return ValueToken(_file, _line, raw, characterLiteral);

            default:
                doError("Not a string");
                break;
        }

        return ValueToken(_file, _line, raw, stringLiteral);
    }

    ValueToken doNumber()
    {
        enum State : ubyte
        {
            start = 0,
            integer,
            prefix,
            suffix,
            fraction,
            exponent,
            bin,
            hex,
            hexfract,
            end
        }

        enum { hex, dec }

        static immutable real[14] negtab =
        [ 1e-4096L,1e-2048L,1e-1024L,1e-512L,1e-256L,1e-128L,1e-64L,1e-32L,
          1e-16L,1e-8L,1e-4L,1e-2L,1e-1L,1.0L ];
        static immutable real[13] postab =
        [ 1e+4096L,1e+2048L,1e+1024L,1e+512L,1e+256L,1e+128L,1e+64L,1e+32L,
          1e+16L,1e+8L,1e+4L,1e+2L,1e+1L ];

        State state = State.start;
        char dot = 0;                        /* if decimal point has been seen */
        int exp = 0;
        ulong msdec = 0, lsdec = 0;
        ulong msscale = 1;
        bool isFloat = false;
        bool isHex = false;
        string raw;

        void parseNumber(alias Format)()
        {
            static if (Format == hex)
            {
                enum uint radix = 16;
                enum ulong msscaleMax = 0x1000_0000_0000_0000UL; // largest power of 16 a ulong holds
                enum ubyte expIter = 4; // iterate the base-2 exponent by 4 for every hex digit
                alias checkDigit = isHexDigit;
                /*
                * convert letter to binary representation: First clear bit
                * to convert lower space chars to upperspace, then -('A'-10)
                * converts letter A to 10, letter B to 11, ...
                */
                alias convertDigit = (int x) => isAlpha(x) ? ((x & ~0x20) - ('A' - 10)) : x - '0';
            }
            else static if (Format == dec)
            {
                enum uint radix = 10;
                enum ulong msscaleMax = 10_000_000_000_000_000_000UL; // largest power of 10 a ulong holds
                enum ubyte expIter = 1; // iterate the base-10 exponent once for every decimal digit
                alias checkDigit = isDigit;
                alias convertDigit = (int x) => x - '0';
            }
            else
                static assert(false, "Unrecognized number format used.");

            // Parse number
            while (checkDigit(peekChar()))
            {                        
                raw ~= getChar();

                if (msdec < (ulong.max - radix) / radix)
                {
                    msdec = msdec * radix + convertDigit(curCh);
                }
                else if (msscale < msscaleMax)
                {
                    lsdec = lsdec * radix + convertDigit(curCh);
                    msscale *= radix;
                }
                else
                {
                    exp += expIter;
                }

                exp -= dot;

                while (peekChar() == '_')
                    getChar();
            }
        }

        while (state != State.end) 
        {
            final switch (state)
            {
                case State.start:
                    if (curCh == '0')
                        state = State.prefix;
                    else if (curCh == '.')
                        state = State.fraction;
                    else if (isDigit(curCh))
                    {
                        state = State.integer;
                        msdec = msdec * 10 + (curCh - '0');
                    } 
                    else
                        doError(text("Unexpected symbol '", curCh, '\''));

                    raw ~= curCh;
                    break;

                case State.integer:
                    // Parse number
                    parseNumber!dec();

                    // Exponent
                    if (peekChar() == 'e')
                    {
                        raw ~= getChar();
                        isFloat = true;
                        state = State.exponent;
                    }
                    else if (peekChar() == '.')
                    {
                        raw ~= getChar();
                        state = State.fraction;
                    }
                    // Integer Suffix
                    else
                        state = State.suffix;
                    break;

                case State.prefix:
                    // Hex
                    if (peekChar() == 'x')
                    {
                        raw ~= getChar();
                        state = State.hex;
                        isHex = true;
                    }
                    // Bin
                    else if (peekChar() == 'b')
                    {
                        raw ~= getChar();
                        state = State.bin;
                    }
                    // Float
                    else if (peekChar() == '.')
                    {
                        raw ~= getChar();
                        state = State.fraction;
                    }
                    // Nil
                    else
                        return ValueToken(_file, _line, "0", 0);
                    break;

                case State.suffix:
                    // Parse integer suffix
                    if (peekChar() == 'u' || peekChar() == 'U') 
                    {
                        raw ~= getChar();
                        if (peekChar() == 'L')
                            raw ~= getChar();
                    }
                    else if (peekChar() == 'L') 
                    {
                        raw ~= getChar();
                        if (peekChar() == 'u' || peekChar() == 'U')
                            raw ~= getChar();
                    }  

                    state = State.end;
                    break;

                case State.fraction:
                    isFloat = true;
                    ++dot;

                    if (!isDigit(peekChar()))
                    {
                        if (isAlpha(peekChar()) || peekChar() == '_')
                            doError("no property `" ~ doIdentifier() ~ "` for type `int`");

                        state = State.end;
                    }

                    // Parse number
                    parseNumber!dec();

                    state = State.end;

                    // Float suffix
                    if (peekChar() == 'L' || 
                        peekChar() == 'F' || 
                        peekChar() == 'f')
                    {
                        raw ~= getChar();
                    }
                    // Exponent
                    else if (peekChar() == 'e')
                    {
                        raw ~= getChar();
                        state = State.exponent;
                    }
                    break;

                case State.exponent: 
                    {
                        int e = 0;
                        bool neg = false;

                        if (peekChar() == '+')
                        {
                            raw ~= getChar();
                        }
                        else if (peekChar() == '-')
                        {
                            raw ~= getChar();
                            neg = true;
                        }

                        if (!isDigit(peekChar()))
                            doError("missing exponent");

                        while (isDigit(peekChar()))
                        {                        
                            raw ~= getChar();

                            if (e < 0x7FFFFFFF / 10 - 10)
                                e = e * 10 + (curCh - '0');
                        }

                        exp += neg ? -e : e;

                        state = State.end;
                    }   break;

                case State.hex:
                    if (!isHexDigit(peekChar()))
                        doError("`0x` isn't a valid integer literal, use `0x0` instead");

                    parseNumber!hex();

                    if (peekChar() == 'p')
                    {
                        raw ~= getChar();
                        isFloat = true;
                        state = State.exponent;
                    }
                    else if (peekChar() == '.')
                    {
                        raw ~= getChar();
                        isFloat = true;
                        dot += 4;
                        state = State.hexfract;
                    }
                    else
                        state = State.suffix;
                    break;

                case State.hexfract:
                    if (!isHexDigit(peekChar()))
                    {
                        if (isAlpha(peekChar()) || peekChar() == '_')
                            doError("no property `" ~ doIdentifier() ~ "` for type `int`");

                        doError("fractional part expected, not `" ~ peekChar() ~ "`");
                    }

                    parseNumber!hex();

                    if (peekChar() == 'p' || peekChar() == 'P')
                    {
                        raw ~= getChar();
                        state = State.exponent;
                    }
                    else
                        doError("exponent required for hex float");
                    break;

                case State.bin:
                    if (peekChar() != '0' && peekChar() != '1')
                    {
                        if (isDigit(peekChar()))
                            doError("binary digit expected, not `" ~ peekChar() ~ "`");

                        doError("`0b` isn't a valid integer literal, use `0b0` instead");
                    }

                    while (peekChar() == '0' || peekChar() == '1')
                    {
                        raw ~= getChar();

                        msdec = msdec * 2 + (curCh - '0');

                        while (peekChar() == '_')
                            getChar();
                    }

                    state = State.suffix;
                    break;

                case State.end:
                    break;                    
            }
        }

        if (isFloat)
        {
            real test = 12.45;
            real ldval = msdec;
            if (msscale != 1)               /* if stuff was accumulated in lsdec */
                ldval = ldval * msscale + lsdec;

            if (isHex)
            {
                import std.math : ldexp;

                // Exponent is power of 2, not power of 10
                ldval = ldexp(ldval, exp);
            }
            else if (ldval)
            {
                uint u = 0;
                int pow = 4096;

                while (exp > 0)
                {
                    while (exp >= pow)
                    {
                        ldval *= postab[u];
                        exp -= pow;
                    }
                    pow >>= 1;
                    u++;
                }

                while (exp < 0)
                {
                    while (exp <= -pow)
                    {
                        ldval *= negtab[u];

                        if (ldval == 0) 
                            doError("range error");

                        exp += pow;
                    }

                    pow >>= 1;
                    u++;
                }
            }

            if (ldval == real.infinity)
                doError("number is too long");

            return ValueToken(_file, _line, raw, ldval);
        }

        return ValueToken(_file, _line, raw, msdec);
    }

    string doIdentifier()
    {
        Char next = peekChar();
        string identifier;

        if (isAlpha(curCh) || curCh == '_')
            identifier ~= curCh;

        while (isAlphaNum(next) || 
               next == '_' ||
               next == '.') 
        {
            identifier ~= getChar();
            next = peekChar();
        }

        return identifier;
    }

    Operator doOperator()
    {
        skipWhitespace();

        switch (curCh)
        {
            case '=':
                if (peekChar() == '>')
                {
                    getChar();
                    return Operator.objectName;
                }
                else if (peekChar() == '=')
                {
                    getChar();
                    return Operator.equal;
                }
                else
                {
                    auto ch = getChar();
                    string op = "=";

                    if (!isAlphaNum(ch) && 
                        ch != '{' &&
                        ch != '[' &&
                        ch != '(' &&
                        ch != '"' &&
                        ch != '\'' &&
                        ch != '_')
                    {
                        op ~= ch;
                    }

                    doError("Unknown operator `" ~ op ~ "`. Did you mean `==` instead?");
                }
                break;

            case '?':
                return Operator.ternaryIf;

            case '|':
                if (peekChar == '|')
                {
                    getChar();
                    return Operator.or;
                }
                return Operator.bitwiseOr;

            case '&':
                if (peekChar == '&')
                {
                    getChar();
                    return Operator.and;
                }
                return Operator.bitwiseAnd;

            case '^':
                return Operator.xor;

            case '!':
                if (peekChar() == '=')
                {
                    getChar();
                    return Operator.notEqual;
                }
                else if (peekChar() == '<')
                {
                    getChar();
                    if (peekChar() == '>')
                    {
                        getChar();
                        if (peekChar() == '=')
                        {
                            getChar();
                            return Operator.unordered;
                        }
                    
                        return Operator.unorderedOrEqual;
                    }
                    else if (peekChar() == '=')
                    {
                        getChar();
                        return Operator.unorderedOrGreater;
                    }
                    
                    return Operator.unorderedGreaterOrEqual;
                }
                else if (peekChar() == '>')
                {
                    getChar();
                    if (peekChar() == '=')
                    {
                        getChar();
                        return Operator.unorderedOrLess;
                    }
                    
                    return Operator.unorderedLessOrEqual;
                }
                return Operator.not;

            case '<':
                if (peekChar() == '=')
                {
                    getChar();
                    return Operator.lessOrEqual;
                }
                else if (peekChar() == '>')
                {
                    getChar();
                    if (peekChar() == '=')
                    {
                        getChar();
                        return Operator.lessGreaterOrEqual;
                    }

                    return Operator.lessOrGreater;
                }
                else if (peekChar() == '<')
                {
                    getChar();
                    return Operator.leftShift;
                }

                return Operator.less;

            case '>':
                if (peekChar() == '=')
                {
                    getChar();
                    return Operator.greaterOrEqual;
                }
                else if (peekChar() == '>')
                {
                    getChar();
                    if (peekChar() == '>')
                    {
                        getChar();
                        return Operator.unsignedRightShift;
                    }

                    return Operator.rightShift;
                }

                return Operator.greater;

            case '+':
                return Operator.add;

            case '-':
                return Operator.sub;

            case '~':
                return Operator.concat;

            case '*':
                return Operator.mul;

            case '/':
                return Operator.div;

            case '%':
                return Operator.mod;

            default:
                return Operator.nop;
        }

        return Operator.nop;
    }

    Token nextToken()
    {
        if (!_nextToken.isNull)
        {
            _curToken = _nextToken.get;
            _nextToken.nullify;
        }
        else
            _curToken = getToken();

        return _curToken;
    }

    Token peekToken()
    {
        if (_nextToken.isNull)
        {
            skipWhitespace();
            if (_text.empty && _nextCh.isNull)
                return Token(Token.Type.eof, _line);

            _nextToken = getToken();
        }

        return _nextToken.get;
    }

    Token checkToken(Token.Type type, string e = null)
    {
        auto token = nextToken();

        if (token.type != type)
            expected(token.line, e == null ? Token.typeToString(type) : e, token.str);

        return token;
    }

    bool testToken(Token.Type type)
    {
        if (peekToken().type == type)
        {
            nextToken();
            return true;
        }

        return false;
    }

    void doModule()
    {
        if (peekToken().type == Token.Type.identifier)
        {
            Token cur = nextToken();

            if (testToken(Token.Type.objectName))
            {
                doObject(cur.data.identifier, checkToken(Token.Type.identifier, "object name").data.identifier);
            }
            else if (peekToken().type == Token.Type.colon)
            {
                _stack ~= Node(Node.Type.object);
                _evt = ParserEvent.startObject;
            }
            else if (peekToken().type == Token.Type.leftBrace)
            {
                doObject(cur.data.identifier);
            }
            else
                expected(peekToken().line, "`{`", peekToken().str);
        }
        else if (peekToken().type == Token.Type.ver)
        {
            _stack ~= Node(Node.Type.object);
            _evt = ParserEvent.startObject;
        }
        else if (peekToken().type == Token.Type.leftBrace)
            doObject();
        else
            expected(peekToken().line, "`{`", peekToken().str);
    }

    void doObject(string objectType = null, string objectName = null)
    {
        checkToken(Token.Type.leftBrace);

        _evt = ParserEvent.startObject;
        _stack ~= Node(Node.Type.object, objectName, objectType);
        _leftBraceCount++;
    }

    void doProperty()
    {
        auto cur = nextToken();

        if (cur.type == Token.Type.ver)
        {
            checkToken(Token.Type.leftBracket);
            cur = checkToken(Token.Type.identifier);
            checkToken(Token.Type.rightBracket);
            checkToken(Token.Type.leftBrace);

            _evt = ParserEvent.startVersionBlock;
            _stack ~= Node(Node.Type.versionBlock, cur.data.identifier);
            _leftBraceCount++;
        }
        else if (cur.type == Token.Type.identifier)
        {
            checkToken(Token.Type.colon);
            _evt = ParserEvent.property;
            _stack ~= Node(Node.Type.property, cur.data.identifier);
        }
        else
            expected(cur.line, "property name", cur.str);
    }

    void doPropertyValue()
    {
        if (peekToken().type == Token.Type.leftBrace)
        {
            doObject();
        }
        else if (testToken(Token.Type.binding))
        {
            _evt = ParserEvent.value;

            if (testToken(Token.Type.leftBrace))
            {
                _value = ValueToken(_file, _line, ValueToken.Type.expressionBinding, "");
                _exprText = "";
                doExpression();
                _value.text = _exprText;
                checkToken(Token.Type.rightBrace);
            }
            else if (peekToken().type == Token.Type.identifier)
                _value = ValueToken(_file, _line, ValueToken.Type.binding, nextToken().data.identifier);
            else
                expected(_line, "property name", peekToken().str);
        }
        else if (testToken(Token.Type.doubleBinding))
        {
            _evt = ParserEvent.value;
            if (peekToken().type == Token.Type.identifier)
                _value = ValueToken(_file, _line, ValueToken.Type.doubleBinding, nextToken().data.identifier);
            else
                expected(_line, "property name", peekToken().str);
        }
        else
            doValue();
    }

    void doValue()
    {
        if (peekToken().type == Token.Type.identifier)
        {
            auto t = nextToken();
            if (testToken(Token.Type.objectName))
            {
                doObject(t.data.identifier, checkToken(Token.Type.identifier, "object name").data.identifier);
            }
            else if (peekToken().type == Token.Type.leftBrace)
            {
                doObject(t.data.identifier);
            }
            else
            {
                _evt = ParserEvent.value;
                _exprText = "";
                doExpression();
                if (_value.type == ValueToken.Type.expression)
                    _value.text = _exprText;
            }
        }
        else if (peekToken().type == Token.Type.leftBrace)
        {
            doObject();
        }
        else if (testToken(Token.Type.leftSquareBracket))
        {
            _evt = ParserEvent.startArray;
            _stack ~= Node(Node.Type.array);
        }
        else
        {
            _evt = ParserEvent.value;
            _exprText = "";
            doExpression();
            if (_value.type == ValueToken.Type.expression)
                _value.text = _exprText;
        }
    }

    void doExpression()
    {
        doOrOr();

        if (peekToken().type == Token.Type.operator &&
            peekToken().data.operator == Operator.ternaryIf)
        {
            nextToken();
            pushValue(ValueToken(_file, _line, Operator.ternaryIf));
            _exprText ~= " ? ";
            doExpression();
            checkToken(Token.Type.colon);
            _exprText ~= " : ";
            pushValue(ValueToken(_file, _line, Operator.ternaryElse));
            doExpression();
        }
    }

    void doOrOr()
    {
        doAndAnd();

        while (peekToken().type == Token.Type.operator)
        {
            if (peekToken().data.operator == Operator.or)
            {
                _exprText ~= " || ";
                nextToken();
                doAndAnd();
                pushValue(ValueToken(_file, _line, Operator.or));
            }
            else 
                break;
        }
    }

    void doAndAnd()
    {
        doOr();

        while (peekToken().type == Token.Type.operator)
        {
            if (peekToken().data.operator == Operator.and)
            {
                _exprText ~= " && ";
                nextToken();
                doOr();
                pushValue(ValueToken(_file, _line, Operator.and));
            }
            else 
                break;
        }
    }

    void doOr()
    {
        doXor();

        while (peekToken().type == Token.Type.operator)
        {
            if (peekToken().data.operator == Operator.bitwiseOr)
            {
                _exprText ~= " | ";
                nextToken();
                doXor();
                pushValue(ValueToken(_file, _line, Operator.bitwiseOr));
            }
            else 
                break;
        }
    }

    void doXor()
    {
        doAnd();

        while (peekToken().type == Token.Type.operator)
        {
            if (peekToken().data.operator == Operator.xor)
            {
                _exprText ~= " ^ ";
                nextToken();
                doAnd();
                pushValue(ValueToken(_file, _line, Operator.xor));
            }
            else 
                break;
        }
    }

    void doAnd()
    {
        doCmp();

        while (peekToken().type == Token.Type.operator)
        {
            if (peekToken().data.operator == Operator.bitwiseAnd)
            {
                _exprText ~= " & ";
                nextToken();
                doCmp();
                pushValue(ValueToken(_file, _line, Operator.bitwiseAnd));
            }
            else 
                break;
        }
    }

    void doCmp()
    {
        doShift();

        while (peekToken().type == Token.Type.operator)
        {
            auto op = peekToken().data.operator;

            if (op == Operator.equal ||
                op == Operator.notEqual ||
                op == Operator.less ||
                op == Operator.lessOrEqual ||
                op == Operator.greater ||
                op == Operator.greaterOrEqual ||
                op == Operator.unordered ||
                op == Operator.unorderedOrEqual ||
                op == Operator.lessOrGreater ||
                op == Operator.lessGreaterOrEqual ||
                op == Operator.unorderedLessOrEqual ||
                op == Operator.unorderedOrLess ||
                op == Operator.unorderedGreaterOrEqual ||
                op == Operator.unorderedOrGreater)
            {
                _exprText ~= text(' ', Operators[op], ' ');
                nextToken();
                doShift();
                pushValue(ValueToken(_file, _line, op));
            }
            else 
                break;
        }
    }

    void doShift()
    {
        doAddSub();

        while (peekToken().type == Token.Type.operator)
        {
            auto op = peekToken().data.operator;

            if (op == Operator.leftShift ||
                op == Operator.rightShift ||
                op == Operator.unsignedRightShift)
            {
                _exprText ~= text(' ', Operators[op], ' ');
                nextToken();
                doAddSub();
                pushValue(ValueToken(_file, _line, op));
            }
            else 
                break;
        }
    }

    void doAddSub()
    {
        doMulDiv();

        while (peekToken().type == Token.Type.operator)
        {
            auto op = peekToken().data.operator;

            if (op == Operator.add ||
                op == Operator.sub ||
                op == Operator.concat)
            {
                _exprText ~= text(' ', Operators[op], ' ');
                nextToken();
                doMulDiv();
                pushValue(ValueToken(_file, _line, op));
            }
            else 
                break;
        }
    }

    void doMulDiv()
    {
        doUnaryExpression();

        while (peekToken().type == Token.Type.operator)
        {
            auto op = peekToken().data.operator;

            if (op == Operator.mul ||
                op == Operator.div ||
                op == Operator.mod)
            {
                _exprText ~= text(' ', Operators[op], ' ');
                nextToken();
                doUnaryExpression();
                pushValue(ValueToken(_file, _line, op));
            }
            else
                break;
        }
    }

    void doUnaryExpression()
    {
        Operator unaryOp = Operator.nop;

        if (peekToken().type == Token.Type.operator)
        {
            auto op = peekToken().data.operator;

            if (op == Operator.add)
            {
                _exprText ~= "+";
                nextToken();
                unaryOp = Operator.unaryPlus;
            }
            else if (op == Operator.sub)
            {
                _exprText ~= "-";
                nextToken();
                unaryOp = Operator.unaryMinus;
            }
            else if (op == Operator.not)
            {
                _exprText ~= "!";
                nextToken();
                unaryOp = Operator.not;
            }                
        }

        doPrimaryExpression();

        if (unaryOp != Operator.nop)
            pushValue(ValueToken(_file, _line, unaryOp));
    }

    void doPrimaryExpression()
    {
        auto token = _curToken.type == Token.Type.identifier 
                   ? _curToken 
                   : nextToken();

        if (token.type == Token.Type.literal)
        {
            _exprText ~= token.data.literal.text;
            pushValue(token.data.literal);
        }
        else if (token.type == Token.Type.identifier)
        {
            _exprText ~= token.data.identifier;
            pushValue(ValueToken(_file, _line, ValueToken.Type.identifier, token.data.identifier));
        }
        else if (token.type == Token.Type.leftBracket)
        {
            _exprText ~= "(";
            doExpression();
            _exprText ~= ")";
            checkToken(Token.Type.rightBracket);
        }
        else
            expected(token.line, "value", token.str);
    }    

    void pushValue(ValueToken value)
    {
        if (_value.type == ValueToken.Type.undefined)
            _value = value;
        else if (_value.type == ValueToken.Type.expression ||
                 _value.type == ValueToken.Type.expressionBinding)
        {
            _value.addToExpr(value);
        }
        else
        {
            ValueToken expr = ValueToken(_value.file, _value.line, ValueToken.Type.expression, "");
            expr.addToExpr(_value);
            expr.addToExpr(value);

            if (expr.expression.length == 1)
                _value = expr.expression[0];
            else
                _value = expr;
        }
    }

    Node findLastNodeByType(Node.Type type) @safe const
    {
        foreach_reverse(node; _stack)
        {
            if (node.type == type)
                return node;
        }

        return Node();
    }

    struct Token
    {
        enum Type
        {
            eof,
            identifier,
            ver,
            colon,
            comma,
            leftBracket,
            rightBracket,
            leftSquareBracket,
            rightSquareBracket,
            leftBrace,
            rightBrace,
            binding,
            doubleBinding,
            objectName,
            operator,
            literal
        }

        union Store
        {
            string identifier;
            Operator operator;
            ValueToken literal;
        }

        @property string str() pure const nothrow
        {
            if (type == Type.identifier)
                return text('`', data.identifier, '`');
            else if (type == Type.operator)
                return text('`', Operators[data.operator], '`');
            else if (type == Type.literal)
            {
                if (data.literal.type == ValueToken.Type._true)
                    return "`true`";
                else if (data.literal.type == ValueToken.Type._false)
                    return "`false`";
                else if (data.literal.type == ValueToken.Type._null)
                    return "`null`";
            }

            return typeToString(type);
        }

        Store data;
        uint line;
        Type type;

        this(Type type, uint line)
        {
            this.type = type;
            this.line = line;
        }

        this(string id, uint line)
        {
            this(Type.identifier, line);
            this.data.identifier = id;
        }

        this(Operator op, uint line)
        {
            this(Type.operator, line);
            this.data.operator = op;
        }

        this(ValueToken literal)
        {
            this(Type.literal, literal.line);
            this.data.literal = literal;
        }

        static string typeToString(Type type) pure @safe nothrow
        {
            final switch (type)
            {
                case Type.eof:
                    return "end of file";
                case Type.identifier:
                    return "identifier";
                case Type.ver:
                    return "version";
                case Type.colon:
                    return "`:`";
                case Type.comma:
                    return "`,`";
                case Type.leftBracket:
                    return "`(`";
                case Type.rightBracket:
                    return "`)`";
                case Type.leftSquareBracket:
                    return "`[`";
                case Type.rightSquareBracket:
                    return "`]`";
                case Type.leftBrace:
                    return "`{`";
                case Type.rightBrace:
                    return "`}`";
                case Type.binding:
                    return "`@`";
                case Type.doubleBinding:
                    return "`@@`";
                case Type.objectName:
                    return "`=>`";
                case Type.operator:
                    return "operator";
                case Type.literal:
                    return "value";
            }
        }
    }

    struct Node
    {
        enum Type {
            none,
            object,
            versionBlock,
            property,
            array,
            dictionary
        }

        this(Type nodeType, string v1 = null, string v2 = null)
        {
            type = nodeType;
            first = v1;
            second = v2;
        }

        string first;
        string second;
        Type   type;
    }

    uint           _line;
    string         _file;
    T              _text;
    ParserEvent    _evt;
    Node[]         _stack;
    Nullable!Char  _nextCh;
    Nullable!Char  _curCh;
    Nullable!Token _nextToken;
    Token          _curToken;
    ValueToken     _value;
    string         _exprText;
    int            _leftBraceCount;
}

Parser!T createParser(T)(T text, uint line = __LINE__, string file = __FILE__)
if (isInputRange!T && !isInfinite!T && isSomeChar!(ElementEncodingType!T))
{
    return Parser!T(text, line, file);
}

unittest
{
    auto p = createParser("");
    assert(p.event == ParserEvent.ready);
    p.next();
    assert(p.event == ParserEvent.end);
    p = createParser("   \t\n");
    assert(p.event == ParserEvent.ready);
    p.next();
    assert(p.event == ParserEvent.end);
}

unittest
{
    auto p = createParser("{} ");
    assert(p.event == ParserEvent.ready);
    p.next();
    assert(p.event == ParserEvent.startObject);
    assert(p.objectName.empty);
    assert(p.objectType.empty);
    p.next();
    assert(p.event == ParserEvent.endObject);
    p.next();
    assert(p.event == ParserEvent.end);
}

unittest 
{
    auto p = createParser(`
        JUICE.Unittest => NumberTest {
            // Decimal Integer
            dec_int: 123,
            dec_int_postfix: 123u,
            dec_int_postfix2: 123uL,
            dec_int_postfix3: 123L,
            // Hex integer
            hex_int: 0xA4,
            hex_int_postfix: 0xA4u,
            hex_int_postfix2: 0xA4L,
            hex_int_postfix3: 0xA4BUL,
            // Binary integer
            bin_int: 0b101010,
            bin_int_postfix: 0b101010u,
            bin_int_postfix2: 0b101010L,
            bin_int_postfix3: 0b101010uL,
            // Decimal float
            dec_float: 12.45,
            dec_float2: .5,
            dec_float3: 115e2,
            dec_float4: 115e-2,
            dec_float_exp: 1.22e3,
            dec_float_exp2: 1.22e+3,
            dec_float_exp3: 1.22e-3,
            // Hex float
            hex_float: 0xAB.CDp1,
            hex_float2: 0xABp2,
            hex_float3: 0xABp-2,
            hex_float4: 0xABp+2,
            hex_float5: 0xA.Bp+3,
            hex_float6: 0xA.Bp-3
        }
    `);

    assert(p.event == ParserEvent.ready);
    p.next();
    assert(p.event == ParserEvent.startObject);
    assert(p.objectName == "NumberTest");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "dec_int");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 123);
    assert(p.value.text == "123");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "dec_int_postfix");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 123);
    assert(p.value.text == "123u");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 123);
    assert(p.value.text == "123uL");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 123);
    assert(p.value.text == "123L");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 0xA4);
    assert(p.value.text == "0xA4");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 0xA4);
    assert(p.value.text == "0xA4u");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 0xA4);
    assert(p.value.text == "0xA4L");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 0xA4B);
    assert(p.value.text == "0xA4BUL");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 0b101010);
    assert(p.value.text == "0b101010");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 0b101010);
    assert(p.value.text == "0b101010u");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 0b101010);
    assert(p.value.text == "0b101010L");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 0b101010);
    assert(p.value.text == "0b101010uL");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.floatLiteral);
    assert(p.value.get!real() == 12.45);
    assert(p.value.text == "12.45");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.floatLiteral);
    assert(p.value.get!real() == .5);
    assert(p.value.text == ".5");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.floatLiteral);
    assert(p.value.get!real() == 115e2);
    assert(p.value.text == "115e2");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.floatLiteral);
    assert(p.value.get!real() == 115e-2);
    assert(p.value.text == "115e-2");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "dec_float_exp");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.floatLiteral);
    assert(p.value.get!double() == 1.22e3);
    assert(p.value.text == "1.22e3");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "dec_float_exp2");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.floatLiteral);
    assert(p.value.get!real() == 1.22e+3);
    assert(p.value.text == "1.22e+3");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "dec_float_exp3");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.floatLiteral);
    assert(p.value.get!real() == 1.22e-3);
    assert(p.value.text == "1.22e-3");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "hex_float");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.floatLiteral);
    assert(p.value.get!real() == 0xAB.CDp1);
    assert(p.value.text == "0xAB.CDp1");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "hex_float2");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.floatLiteral);
    assert(p.value.get!real() == 0xABp2);
    assert(p.value.text == "0xABp2");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "hex_float3");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.floatLiteral);
    assert(p.value.get!real() == 0xABp-2);
    assert(p.value.text == "0xABp-2");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "hex_float4");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.floatLiteral);
    assert(p.value.get!real() == 0xABp+2);
    assert(p.value.text == "0xABp+2");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "hex_float5");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.floatLiteral);
    assert(p.value.get!real() == 0xA.Bp+3);
    assert(p.value.text == "0xA.Bp+3");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "hex_float6");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.floatLiteral);
    assert(p.value.get!real() == 0xA.Bp-3);
    assert(p.value.text == "0xA.Bp-3");
    p.next();
    assert(p.event == ParserEvent.endObject);
    assert(p.objectName == "NumberTest");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.end);
}

unittest
{
    auto p = createParser(`
        JUICE.Unittest => StringTest {
            /*//** String literals /***/
            str: "This is a simple string \U0001F632",
            str1: "String with \"quotes\" \&amp;\t\&lt;symbols\&gt; \u00a9",
            wysiwyg_str: r"This is a \WYSIWYG\ string",
            alternate_wysiwyg_str:` ~ "`This is a \"WYSYWYG\" string`, " ~ `
            /*** Character literals ***/
            ch1: '\t',
            ch2: '*',
            ch3: ' '            
        }`
    );

    assert(p.event == ParserEvent.ready);
    p.next();
    assert(p.event == ParserEvent.startObject);
    assert(p.objectName == "StringTest");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "str");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.stringLiteral);
    assert(p.value.get!string() == "This is a simple string \U0001F632");
    assert(p.value.text == `"This is a simple string \U0001F632"`);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "str1");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.stringLiteral);
    assert(p.value.get!string() == "String with \"quotes\" \&amp;\t\&lt;symbols\&gt; \u00A9");
    assert(p.value.text == `"String with \"quotes\" \&amp;\t\&lt;symbols\&gt; \u00a9"`);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "wysiwyg_str");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.stringLiteral);
    assert(p.value.get!string() == r"This is a \WYSIWYG\ string");
    assert(p.value.text == `r"This is a \WYSIWYG\ string"`);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "alternate_wysiwyg_str");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.stringLiteral);
    assert(p.value.get!string() == `This is a "WYSYWYG" string`);
    assert(p.value.text == "`This is a \"WYSYWYG\" string`");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!char() == '\t');
    assert(p.value.text == "'\\t'");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!char() == '*');
    assert(p.value.text == "'*'");
    p.next();
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!char() == ' ');
    assert(p.value.text == "' '");
    p.next();
    assert(p.event == ParserEvent.endObject);
    assert(p.objectName == "StringTest");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.end);
}

unittest
{
    auto p = createParser(`
        JUICE.Unittest => GenericTest {
            property1: 0,
            version (unittest) {
                property2: 2,
                property3: 3,
            }
            property4: 4,
            version (Win32) {
                property2: 20,
                property3: 30,
            },
            property5: 5,
            prop_set: {
                size: 10,
                fall: 0,
                thru: 11
            },
            cls: JUICE.Unittest {
                text: "Text",
                tag: 11,
                subcls: JUICE.Unittest => Sub1 {
                    sub_p1: 10,
                    sub_p2: 20,
                }
            }
        }`
    );

    assert(p.event == ParserEvent.ready);
    p.next();
    assert(p.event == ParserEvent.startObject);
    assert(p.objectName == "GenericTest");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "property1");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 0);
    p.next();
    assert(p.event == ParserEvent.startVersionBlock);
    assert(p.versionStr == "unittest");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "property2");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 2);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "property3");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 3);
    p.next();
    assert(p.event == ParserEvent.endVersionBlock);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "property4");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 4);
    p.next();
    assert(p.event == ParserEvent.startVersionBlock);
    assert(p.versionStr == "Win32");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "property2");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 20);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "property3");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 30);
    p.next();
    assert(p.event == ParserEvent.endVersionBlock);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "property5");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 5);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "prop_set");
    p.next();
    assert(p.event == ParserEvent.startObject);
    assert(p.objectName == "");
    assert(p.objectType == "");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "size");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 10);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "fall");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 0);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "thru");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 11);
    p.next();
    assert(p.event == ParserEvent.endObject);
    assert(p.objectName == "");
    assert(p.objectType == "");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "cls");
    assert(p.objectName == "GenericTest");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.startObject);
    assert(p.objectName == "");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "text");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.stringLiteral);
    assert(p.value.get!string() == "Text");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "tag");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 11);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "subcls");
    p.next();
    assert(p.event == ParserEvent.startObject);
    assert(p.objectName == "Sub1");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "sub_p1");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 10);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "sub_p2");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 20);
    p.next();
    assert(p.event == ParserEvent.endObject);
    assert(p.objectName == "Sub1");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.endObject);
    assert(p.objectName == "");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.endObject);
    assert(p.objectName == "GenericTest");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.end);
}

unittest 
{
    auto p = createParser(`
        JUICE.Unittest => ArraysTest {
            simple: 1,
            numbers: [1, 2, 3, 4, 5],
            strings: ["Array", "of", "strings"],
            objects: [
                JUICE.Unittest => Content1 {
                    tag: 1
                },
                JUICE.Unittest => Content2 {
                    tag: 2
                },
                JUICE.Unittest => Content3 {
                    tag: 3
                }
            ],
            associative: [
                1: "value1",
                2: JUICE.Unittest {
                    value: 20
                },
                3: JUICE.Unittest => Value3 {
                }
            ],
            nestedArrays: [
                [ 1, 2, 3 ],
                [ 4, 5, 6 ],
                [ 7, 8, 9 ]
            ]
        }
    `);

    assert(p.event == ParserEvent.ready);
    p.next();
    assert(p.event == ParserEvent.startObject);
    assert(p.objectName == "ArraysTest");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "simple");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 1);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "numbers");
    p.next();
    assert(p.event == ParserEvent.startArray);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 1);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 2);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 3);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 4);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 5);
    p.next();
    assert(p.event == ParserEvent.endArray);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "strings");
    p.next();
    assert(p.event == ParserEvent.startArray);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.stringLiteral);
    assert(p.value.get!string() == "Array");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.stringLiteral);
    assert(p.value.get!string() == "of");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.stringLiteral);
    assert(p.value.get!string() == "strings");
    p.next();
    assert(p.event == ParserEvent.endArray);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "objects");
    p.next();
    assert(p.event == ParserEvent.startArray);
    p.next();
    assert(p.event == ParserEvent.startObject);
    assert(p.objectName == "Content1");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "tag");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 1);
    p.next();
    assert(p.event == ParserEvent.endObject);
    assert(p.objectName == "Content1");
    p.next();
    assert(p.event == ParserEvent.startObject);
    assert(p.objectName == "Content2");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "tag");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 2);
    p.next();
    assert(p.event == ParserEvent.endObject);
    assert(p.objectName == "Content2");
    p.next();
    assert(p.event == ParserEvent.startObject);
    assert(p.objectName == "Content3");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "tag");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 3);
    p.next();
    assert(p.event == ParserEvent.endObject);
    assert(p.objectName == "Content3");
    p.next();
    assert(p.event == ParserEvent.endArray);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "associative");
    p.next();
    assert(p.event == ParserEvent.startArray);
    p.next();
    assert(p.event == ParserEvent.key);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 1);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.stringLiteral);
    assert(p.value.get!string() == "value1");
    p.next();
    assert(p.event == ParserEvent.key);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 2);
    p.next();
    assert(p.event == ParserEvent.startObject);
    assert(p.objectName == "");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "value");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 20);
    p.next();
    assert(p.event == ParserEvent.endObject);
    p.next();
    assert(p.event == ParserEvent.key);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 3);
    p.next();
    assert(p.event == ParserEvent.startObject);
    assert(p.objectName == "Value3");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.endObject);
    p.next();
    assert(p.event == ParserEvent.endArray);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "nestedArrays");
    p.next();
    assert(p.event == ParserEvent.startArray);
    p.next();
    assert(p.event == ParserEvent.startArray);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 1);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 2);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 3);
    p.next();
    assert(p.event == ParserEvent.endArray);
    p.next();
    assert(p.event == ParserEvent.startArray);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 4);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 5);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 6);
    p.next();
    assert(p.event == ParserEvent.endArray);
    p.next();
    assert(p.event == ParserEvent.startArray);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 7);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 8);
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == 9);
    p.next();
    assert(p.event == ParserEvent.endArray);
    p.next();
    assert(p.event == ParserEvent.endArray);
    p.next();
    assert(p.event == ParserEvent.endObject);
    p.next();
    assert(p.event == ParserEvent.end);
}

unittest 
{
    auto p = createParser(`
        JUICE.Unittest => ExpressionTest {
            unary: -93,
            boolval: true,
            simple: -a + b * c,
            brackets: (a+b)/(a - b),
            unaryBr: -(-c + a + -93) * b,
            logic: a > 0 && (b + 10 < 100 || c >= 5),
            logic2: a >> v == 15 || b & 0b00000001u
        }
    `);

    assert(p.event == ParserEvent.ready);
    p.next();
    assert(p.event == ParserEvent.startObject);
    assert(p.objectName == "ExpressionTest");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "unary");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.integerLiteral);
    assert(p.value.get!int() == -93);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "boolval");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type._true);
    assert(p.value.get!bool() == true);
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "simple");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.expression);
    assert(p.value.expression.length == 6);
    assert(p.value.expression[0].type == ValueToken.Type.identifier);
    assert(p.value.expression[0].get!string == "a");
    assert(p.value.expression[1].type == ValueToken.Type.operator);
    assert(p.value.expression[1].get!Operator == Operator.unaryMinus);
    assert(p.value.expression[2].type == ValueToken.Type.identifier);
    assert(p.value.expression[2].get!string == "b");
    assert(p.value.expression[3].type == ValueToken.Type.identifier);
    assert(p.value.expression[3].get!string == "c");
    assert(p.value.expression[4].type == ValueToken.Type.operator);
    assert(p.value.expression[4].get!Operator == Operator.mul);
    assert(p.value.expression[5].type == ValueToken.Type.operator);
    assert(p.value.expression[5].get!Operator == Operator.add);
    assert(p.value.text == "-a + b * c");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "brackets");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.expression);
    assert(p.value.expression.length == 7);
    assert(p.value.expression[0].type == ValueToken.Type.identifier);
    assert(p.value.expression[0].get!string == "a");
    assert(p.value.expression[1].type == ValueToken.Type.identifier);
    assert(p.value.expression[1].get!string == "b");
    assert(p.value.expression[2].type == ValueToken.Type.operator);
    assert(p.value.expression[2].get!Operator == Operator.add);
    assert(p.value.expression[3].type == ValueToken.Type.identifier);
    assert(p.value.expression[3].get!string == "a");
    assert(p.value.expression[4].type == ValueToken.Type.identifier);
    assert(p.value.expression[4].get!string == "b");
    assert(p.value.expression[5].type == ValueToken.Type.operator);
    assert(p.value.expression[5].get!Operator == Operator.sub);
    assert(p.value.expression[6].type == ValueToken.Type.operator);
    assert(p.value.expression[6].get!Operator == Operator.div);
    assert(p.value.text == "(a + b) / (a - b)");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "unaryBr");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.expression);
    assert(p.value.expression.length == 9);
    assert(p.value.expression[0].type == ValueToken.Type.identifier);
    assert(p.value.expression[0].get!string == "c");
    assert(p.value.expression[1].type == ValueToken.Type.operator);
    assert(p.value.expression[1].get!Operator == Operator.unaryMinus);
    assert(p.value.expression[2].type == ValueToken.Type.identifier);
    assert(p.value.expression[2].get!string == "a");
    assert(p.value.expression[3].type == ValueToken.Type.operator);
    assert(p.value.expression[3].get!Operator == Operator.add);
    assert(p.value.expression[4].type == ValueToken.Type.integerLiteral);
    assert(p.value.expression[4].get!int() == -93);
    assert(p.value.expression[5].type == ValueToken.Type.operator);
    assert(p.value.expression[5].get!Operator == Operator.add);
    assert(p.value.expression[6].type == ValueToken.Type.operator);
    assert(p.value.expression[6].get!Operator == Operator.unaryMinus);
    assert(p.value.expression[7].type == ValueToken.Type.identifier);
    assert(p.value.expression[7].get!string == "b");
    assert(p.value.expression[8].type == ValueToken.Type.operator);
    assert(p.value.expression[8].get!Operator == Operator.mul);
    assert(p.value.text == "-(-c + a + -93) * b");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "logic");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.expression);
    assert(p.value.expression.length == 13);
    assert(p.value.expression[0].type == ValueToken.Type.identifier);
    assert(p.value.expression[0].get!string() == "a");
    assert(p.value.expression[1].type == ValueToken.Type.integerLiteral);
    assert(p.value.expression[1].get!int() == 0);
    assert(p.value.expression[2].type == ValueToken.Type.operator);
    assert(p.value.expression[2].get!Operator == Operator.greater);
    assert(p.value.expression[3].type == ValueToken.Type.identifier);
    assert(p.value.expression[3].get!string() == "b");
    assert(p.value.expression[4].type == ValueToken.Type.integerLiteral);
    assert(p.value.expression[4].get!int() == 10);
    assert(p.value.expression[5].type == ValueToken.Type.operator);
    assert(p.value.expression[5].get!Operator == Operator.add);
    assert(p.value.expression[6].type == ValueToken.Type.integerLiteral);
    assert(p.value.expression[6].get!int() == 100);
    assert(p.value.expression[7].type == ValueToken.Type.operator);
    assert(p.value.expression[7].get!Operator == Operator.less);
    assert(p.value.expression[8].type == ValueToken.Type.identifier);
    assert(p.value.expression[8].get!string() == "c");
    assert(p.value.expression[9].type == ValueToken.Type.integerLiteral);
    assert(p.value.expression[9].get!int() == 5);
    assert(p.value.expression[10].type == ValueToken.Type.operator);
    assert(p.value.expression[10].get!Operator == Operator.greaterOrEqual);
    assert(p.value.expression[11].type == ValueToken.Type.operator);
    assert(p.value.expression[11].get!Operator == Operator.or);
    assert(p.value.expression[12].type == ValueToken.Type.operator);
    assert(p.value.expression[12].get!Operator == Operator.and);
    assert(p.value.text == "a > 0 && (b + 10 < 100 || c >= 5)");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "logic2");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.expression);
    assert(p.value.expression.length == 9);
    assert(p.value.expression[0].type == ValueToken.Type.identifier);
    assert(p.value.expression[0].get!string() == "a");
    assert(p.value.expression[1].type == ValueToken.Type.identifier);
    assert(p.value.expression[1].get!string() == "v");
    assert(p.value.expression[2].type == ValueToken.Type.operator);
    assert(p.value.expression[2].get!Operator == Operator.rightShift);
    assert(p.value.expression[3].type == ValueToken.Type.integerLiteral);
    assert(p.value.expression[3].get!int() == 15);
    assert(p.value.expression[4].type == ValueToken.Type.operator);
    assert(p.value.expression[4].get!Operator == Operator.equal);
    assert(p.value.expression[5].type == ValueToken.Type.identifier);
    assert(p.value.expression[5].get!string() == "b");
    assert(p.value.expression[6].type == ValueToken.Type.integerLiteral);
    assert(p.value.expression[6].get!int() == 1);
    assert(p.value.expression[7].type == ValueToken.Type.operator);
    assert(p.value.expression[7].get!Operator == Operator.bitwiseAnd);
    assert(p.value.expression[8].type == ValueToken.Type.operator);
    assert(p.value.expression[8].get!Operator == Operator.or);
    assert(p.value.text == "a >> v == 15 || b & 0b00000001u");
    p.next();
    assert(p.event == ParserEvent.endObject);
    p.next();
    assert(p.event == ParserEvent.end);
}

unittest 
{
    auto p = createParser(`
        JUICE.Unittest => BindingTest {
            simple: @Object.property,
            simple_expr: @{Obj.bind},
            expression: @{ Obj.tag > 0 ? Enum.Value1 : Enum.Value2 | 0b0100111 },
            double: @@Obj.prop2
        }
    `);

    assert(p.event == ParserEvent.ready);
    p.next();
    assert(p.event == ParserEvent.startObject);
    assert(p.objectName == "BindingTest");
    assert(p.objectType == "JUICE.Unittest");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "simple");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.binding);
    assert(p.value.text == "Object.property");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "simple_expr");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.expressionBinding);
    assert(p.value.expression.length == 1);
    assert(p.value.expression[0].type == ValueToken.Type.identifier);
    assert(p.value.expression[0].get!string() == "Obj.bind");
    assert(p.value.text == "Obj.bind");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "expression");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.expressionBinding);
    assert(p.value.expression.length == 9);
    assert(p.value.expression[0].type == ValueToken.Type.identifier);
    assert(p.value.expression[0].get!string() == "Obj.tag");
    assert(p.value.expression[1].type == ValueToken.Type.integerLiteral);
    assert(p.value.expression[1].get!int() == 0);
    assert(p.value.expression[2].type == ValueToken.Type.operator);
    assert(p.value.expression[2].get!Operator == Operator.greater);
    assert(p.value.expression[3].type == ValueToken.Type.operator);
    assert(p.value.expression[3].get!Operator == Operator.ternaryIf);
    assert(p.value.expression[4].type == ValueToken.Type.identifier);
    assert(p.value.expression[4].get!string() == "Enum.Value1");
    assert(p.value.expression[5].type == ValueToken.Type.operator);
    assert(p.value.expression[5].get!Operator == Operator.ternaryElse);
    assert(p.value.expression[6].type == ValueToken.Type.identifier);
    assert(p.value.expression[6].get!string() == "Enum.Value2");
    assert(p.value.expression[7].type == ValueToken.Type.integerLiteral);
    assert(p.value.expression[7].get!int() == 0b0100111);
    assert(p.value.expression[8].type == ValueToken.Type.operator);
    assert(p.value.expression[8].get!Operator == Operator.bitwiseOr);
    assert(p.value.text == "Obj.tag > 0 ? Enum.Value1 : Enum.Value2 | 0b0100111");
    p.next();
    assert(p.event == ParserEvent.property);
    assert(p.property == "double");
    p.next();
    assert(p.event == ParserEvent.value);
    assert(p.value.type == ValueToken.Type.doubleBinding);
    assert(p.value.get!string() == "Obj.prop2");
    p.next();
    assert(p.event == ParserEvent.endObject);
    p.next();
    assert(p.event == ParserEvent.end);
}