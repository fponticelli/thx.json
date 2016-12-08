package thx.json.schema;

import haxe.ds.Option;
import haxe.ds.StringMap;

import thx.Any;
import thx.Strings;
import thx.Unit;
import thx.Validation;
import thx.Validation.*;
import thx.fp.Writer;
using thx.Arrays;
using thx.Functions;
using thx.Maps;
using thx.Options;

import thx.Validation;
import thx.schema.SchemaF;
import thx.schema.SchemaDSL;
import thx.schema.SchemaDSL.*;
using thx.schema.SchemaFExtensions;

import thx.json.JValue;
import thx.json.JValue.*;

class SchemaExtensions {
  inline static public function fail<A>(message: String, path: JPath): VNel<ParseError<String>, A>
    return failureNel(new ParseError(message, path));

  public static function parseJSON<A, E>(schema: Schema<String, A>, v: JValue): VNel<ParseError<String>, A> {
    return parseJSON0(schema, v, JPath.root);
  }

  private static function parseJSON0<A>(schema: Schema<String, A>, v: JValue, path: JPath): VNel<ParseError<String>, A> {
    // helper function used to unpack existential type I
    return switch schema.schema {
      case IntSchema:
        switch v {
          case JNum(n): 
            if (Math.round(n) == n) successNel(Math.round(n)) 
            else fail('$n is not an integer value.', path);
          case other: 
            fail('Value ${Render.renderUnsafe(v)} is not a JSON numeric value.', path);
        };

      case FloatSchema:
        switch v {
          case JNum(n): successNel(n);
          case other: fail('Value ${Render.renderUnsafe(v)} is not a JSON numeric value.', path);
        }

      case StrSchema:
        switch v {
          case JString(s): successNel(s);
          case other: fail('Value ${Render.renderUnsafe(v)} is not a JSON string value.', path);
        };

      case BoolSchema:
        switch v {
          case JBool(b): successNel(b);
          case other: fail('Value ${Render.renderUnsafe(v)} is not a JSON boolean value.', path);
        };

      case ConstSchema(a): 
        switch v {
          case JNull: successNel(a);
          case other: fail('Value ${Render.renderUnsafe(v)} is not JSON null.', path);
        };

      case AnySchema: 
        successNel(Any.ofValue(v));

      case ObjectSchema(propSchema):
        parseObject(propSchema, v, path);

      case ArraySchema(elemSchema): 
        switch v {
          case JArray(values): values.traverseValidationIndexed(function(v, i) return parseJSON0(elemSchema, v, path * i), Nel.semigroup());
          case other: fail('Value ${Render.renderUnsafe(v)} is not a JSON array.', path);
        };

      case MapSchema(elemSchema):
        switch v {
          case JObject(assocs): 
            var validatedAssocs = assocs.traverseValidation(
               function(v) return parseJSON0(elemSchema, v.value, path / v.name).map(Tuple.of.bind(v.name, _)), 
               Nel.semigroup()
            );

            validatedAssocs.map(Arrays.toStringMap);

          case other: 
            fail('Value ${Render.renderUnsafe(v)} is not a JSON object.', path);
        };

      case OneOfSchema(alternatives):
        if (alternatives.all(function(a) return a.isConstantAlt())) {
          switch v {
            case JString(s):
              var id0 = s.toLowerCase();
              switch alternatives.findOption.fn(_.id().toLowerCase() == id0) {
                case Some(Prism(id, base, f, _)): parseJSON0(base, jNull, path / id).map(f);
                case None: fail('Value ${Render.renderUnsafe(v)} cannot be mapped to any of ${alternatives.map.fn(_.id())}.', path);
              };

            case other: 
              fail('Value ${Render.renderUnsafe(v)} is not a JSON string.', path);
          }
        } else {
          switch v {
            case JObject(assocs): 
              // This is specific to the encoding which demands that exactly one of the map's keys is 
              // represented among the alternatives
              switch assocs.flatMap(function(a) return alternatives.filter.fn(_.id() == a.name)) {
                case [Prism(id, base, f, _)]:
                  parseAlternative(id, base, v, path / id).map(f);

                case other:
                  if (other.length == 0) {
                    fail('Could not match type identifier from among ${alternatives.map.fn(_.id())} among keys ${assocs.map.fn(_.name)}', path);
                  } else {
                    fail('Ambiguous JSON value ${Render.renderUnsafe(v)}: all of ${other.map.fn(_.id())} are valid type identifiers.', path);
                  }
              }

            case other: 
              fail('Value ${Render.renderUnsafe(v)} is not a JSON object.', path);
          }
        }

      case ParseSchema(base, f, _): 
        parseJSON0(base, v, path).flatMapV(
          function(v0) return switch f(v0) {
            case PSuccess(a): successNel(a);
            case PFailure(err, _): fail(err, path);
          }
        );

      case LazySchema(base):
        parseJSON0(base(), v, path);
    };
  }

  /**
   * This helper function is the companion to alternativeSchema; both
   * are private helpers for the parse and jsonSchema functions, respectively
   */ 
  private static function parseAlternative<A>(id: String, schema: Schema<String, A>, value: JValue, path: JPath): VNel<ParseError<String>, A> {
    function parseAltPrimitive<X>(schema: Schema<String, X>, assocs: ReadonlyArray<JAssoc>): VNel<ParseError<String>, X> {
      return switch assocs.findOption.fn(_.name == id) {
        case Some(v): parseJSON0(schema, v.value, path / id);
        case None: fail('Object ${Render.renderUnsafe(value)} does not contain required property $id', path);
      };
    }

    return switch value {
      case JObject(assocs):
        switch schema.schema {
          case ConstSchema(a): successNel(a);
          case ParseSchema(base, f, _): 
            parseAlternative(id, base, value, path).flatMapV(
              function(baseValue) return switch f(baseValue) {
                case PSuccess(a): successNel(a);
                case PFailure(e, s): fail(e, path);

              }
            );
          case LazySchema(base): parseAlternative(id, base(), value, path);
          case _: parseAltPrimitive(schema, assocs); 
        };

      case other:
        fail('Value ${Render.renderUnsafe(value)} is not a JSON object.', path);
    };
  }

  private static function parseObject<O, A>(builder: PropsBuilder<String, Unit, O, A>, v: JValue, path: JPath): VNel<ParseError<String>, A> {
    // helper function used to unpack existential type I
    inline function go<I>(schema: PropSchema<String, Unit, O, I>, k: PropsBuilder<String, Unit, O, I -> A>): VNel<ParseError<String>, A> {
      var parsed: VNel<ParseError<String>, I> = switch v {
        case JObject(assocs):
          switch schema {
            case Required(fieldName, valueSchema, _):
              switch assocs.findOption(function(a) return a.name == fieldName) {
                case Some(assoc):
                  parseJSON0(valueSchema, assoc.value, path / fieldName);

                case None: 
                  fail('Value ${Render.renderUnsafe(v)} does not contain key ${fieldName} and no default was available.', path);
              };

            case Optional(fieldName, valueSchema, _, dflt):
              var assoc: Option<JAssoc> = assocs.findOption(function(a) return a.name == fieldName);
              assoc.traverseValidation(function(a: JAssoc) return parseJSON0(valueSchema, a.value, path / fieldName)).map.fn(_.orElse(dflt));
          };

        case other: 
          fail('Value ${Render.renderUnsafe(v)} is not a JSON object.', path);
      };

      return parsed.ap(parseObject(k, v, path), Nel.semigroup());
    }

    return switch builder {
      case Pure(a): successNel(a);
      case Ap(s, k): go(s, k);
    };
  }

  public static function renderJSON<E, A>(schema: Schema<E, A>, value: A): JValue {
    return switch schema.schema {
      case BoolSchema:  jBool(value);
      case FloatSchema: jNum(value);
      case IntSchema:   jNum(value * 1.0);
      case StrSchema:   jString(value);
      case ConstSchema(_):  jNull;
      case AnySchema:       jNull; // cannot render Any to JSON

      case ObjectSchema(propSchema): renderObject(propSchema, value);
                          
      case ArraySchema(elemSchema): jArray(value.map(renderJSON.bind(elemSchema, _)));

      case MapSchema(elemSchema): jObject(value.mapValues(renderJSON.bind(elemSchema, _), new Map()));

      case OneOfSchema(alternatives): 
        var selected: Array<JValue> = alternatives.flatMap(
          function(alt) return switch alt {
            case Prism(id, base, _, g): 
              return g(value).map(
                function(b) return if (alternatives.all.fn(_.isConstantAlt())) {
                  jString(id); 
                } else {
                  jObject([id => renderJSON(base, b) ]);
                }
              ).toArray();
          }
        );

        switch selected {
          case [result]: result;
          case []:   throw new thx.Error('None of ${alternatives.map.fn(_.id())} could convert the value $value to the base type ${schema.schema.stype()}');
          case mult: throw new thx.Error('Ambiguous value $value: (all of ${mult.map(Render.renderUnsafe)}) claim to be valid renderings.');
        }

      case ParseSchema(base, _, g): 
        renderJSON(base, g(value));

      case LazySchema(base):
        renderJSON(base(), value);
    }
  }

  public static function renderObject<E, A>(builder: ObjectBuilder<E, Unit, A>, value: A): JValue {
    return JObject(evalRO(builder, value).runLog());
  }

  // should be inside renderObject, but haxe doesn't let you write corecursive
  // functions as inner functions
  private static function evalRO<E, O, A>(builder: PropsBuilder<E, Unit, O, A>, value: O): Writer<Array<JAssoc>, A>
    return switch builder {
      case Pure(a): Writer.pure(a, wm);
      case Ap(s, k): goRO(s, k, value);
    };

  // should be inside renderObject, but haxe doesn't let you write corecursive
  // functions as inner functions
  private static function goRO<E, O, I, J>(schema: PropSchema<E, Unit, O, I>, k: PropsBuilder<E, Unit, O, I -> J>, value: O): Writer<Array<JAssoc>, J> {
    var action: Writer<Array<JAssoc>, I> = switch schema {
      case Required(field, valueSchema, accessor):
        var i0 = accessor(value);
        Writer.tell([{ name: field, value: renderJSON(valueSchema, i0) }], wm) >> 
        Writer.pure(i0, wm);

      case Optional(field, valueSchema, accessor, dflt):
        var i0 = accessor(value).orElse(dflt);
        Writer.tell(i0.map(function(v0) return { name: field, value: renderJSON(valueSchema, v0) }).toArray(), wm) >> 
        Writer.pure(i0, wm);
    }

    return action.ap(evalRO(k, value));
  }

  // This value will be reused a bunch, so no need to re-create it all the time.
  private static var wm(default, never): Monoid<Array<JAssoc>> = Arrays.monoid();
}

class ParseError<E> {
  public var error(default, null): E;
  public var path(default, null): JPath;

  public function new(error: E, path: JPath) {
    this.error = error;
    this.path = path;
  }

  public function toString(): String {
    return '${path.toString()}: ${error}';
  }
}
