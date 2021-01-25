(** Copyright (c) 2020 Sam Westrick
  *
  * See the file LICENSE for details.
  *)

structure Parser:
sig
  exception Error of LineError.t
  val parse: Source.t -> Ast.t
end =
struct

  exception Error of LineError.t

  fun error {what, pos, explain} =
    raise Error
      { header = "PARSE ERROR"
      , pos = pos
      , what = what
      , explain = explain
      }


  fun seqFromRevList list = Seq.rev (Seq.fromList list)


  fun makeInfix infdict (left, id, right) =
    let
      val hp = InfixDict.higherPrecedence infdict
      val sp = InfixDict.samePrecedence infdict
      val aLeft = InfixDict.associatesLeft infdict
      val aRight = InfixDict.associatesRight infdict

      fun bothLeft (x, y) = aLeft x andalso aLeft y
      fun bothRight (x, y) = aRight x andalso aRight y

      val default =
        Ast.Exp.Infix
          { left = left
          , id = id
          , right = right
          }
    in
      case right of
        Ast.Exp.Infix {left=rLeft, id=rId, right=rRight} =>
          if hp (rId, id) orelse (sp (rId, id) andalso bothRight (rId, id)) then
            default
          else if hp (id, rId) orelse (sp (rId, id) andalso bothLeft (rId, id)) then
            Ast.Exp.Infix
              { left = makeInfix infdict (left, id, rLeft)
              , id = rId
              , right = rRight
              }
          else
            error
              { pos = Token.getSource rId
              , what = "Ambiguous infix expression."
              , explain =
                  SOME "You are not allowed to mix left- and right-associative \
                       \operators of same precedence"
              }

      | _ =>
          default
    end


  fun updateInfixDict infdict dec =
    let
      fun parsePrec p =
        case p of
          NONE => 0
        | SOME x =>
            case Int.fromString (Token.toString x) of
              SOME y => y
            | NONE => raise Fail "Bug: updateInfixDict.parsePrec"
    in
      case dec of
        Ast.Exp.DecInfix {precedence, elems, ...} =>
          let
            val p = parsePrec precedence
            fun mk tok = (tok, p, InfixDict.AssocLeft)
          in
            Seq.iterate (fn (d, tok) => InfixDict.insert d (mk tok))
              infdict
              elems
          end

      | Ast.Exp.DecInfixr {precedence, elems, ...} =>
          let
            val p = parsePrec precedence
            fun mk tok = (tok, p, InfixDict.AssocRight)
          in
            Seq.iterate (fn (d, tok) => InfixDict.insert d (mk tok))
              infdict
              elems
          end

      | Ast.Exp.DecNonfix {elems, ...} =>
          Seq.iterate (fn (d, tok) => InfixDict.remove d tok)
            infdict
            elems

      | _ =>
        raise Fail "Bug: Parser.updateInfixDict: argument is not an infixity dec"
    end



  (** This just implements a dumb little ordering:
    *   AtExp < AppExp < InfExp < Exp
    * and then e.g. `appExpOkay r` checks `AppExp < r`
    *)
  datatype exp_restrict =
    AtExpRestriction    (* AtExp *)
  | AppExpRestriction   (* AppExp *)
  | InfExpRestriction   (* InfExp *)
  | NoRestriction       (* Exp *)
  fun appExpOkay restrict =
    case restrict of
      AtExpRestriction => false
    | _ => true
  fun infExpOkay restrict =
    case restrict of
      AtExpRestriction => false
    | AppExpRestriction => false
    | _ => true
  fun anyExpOkay restrict =
    case restrict of
      NoRestriction => true
    | _ => false


  type ('state, 'result) parser = 'state -> ('state * 'result)
  type 'state peeker = 'state -> bool


  fun parse src =
    let
      (** This might raise Lexer.Error *)
      val toksWithComments = Lexer.tokens src
      val toks = Seq.filter (not o Token.isComment) toksWithComments
      val numToks = Seq.length toks
      fun tok i = Seq.nth toks i


      (** not yet implemented *)
      fun nyi fname i =
        if i >= numToks then
          raise Error
            { header = "ERROR: NOT YET IMPLEMENTED"
            , pos = Token.getSource (tok (numToks-1))
            , what = "Unexpected EOF after token."
            , explain = SOME ("(TODO: Sam: see Parser.parse." ^ fname ^ ")")
            }
        else if i >= 0 then
          raise Error
            { header = "ERROR: NOT YET IMPLEMENTED"
            , pos = Token.getSource (tok i)
            , what = "Unexpected token."
            , explain = SOME ("(TODO: Sam: see Parser.parse." ^ fname ^ ")")
            }
        else
          raise Fail ("Bug: Parser.parse." ^ fname ^ ": position out of bounds??")


      (** This silliness lets you write almost-English like this:
        *   if is Token.Identifier at i           then ...
        *   if isReserved Token.Val at i          then ...
        *   if check isTyVar at i                 then ...
        *)
      infix 5 at
      fun f at i = f i
      fun check f i = i < numToks andalso f (tok i)
      fun is c = check (fn t => c = Token.getClass t)
      fun isReserved rc = check (fn t => Token.Reserved rc = Token.getClass t)


      (** parse_reservedToken:
        *   Token.reserved -> (int, Token.t) parser
        *)
      fun parse_reservedToken rc i =
        if isReserved rc at i then
          (i+1, tok i)
        else
          error
            { pos = Token.getSource (tok i)
            , what =
                "Unexpected token. Expected to see "
                ^ "'" ^ Token.reservedToString rc ^ "'"
            , explain = NONE
            }

      (** parse_zeroOrMoreDelimitedByReserved
        *   { parseElem: (int, 'a) parser
        *   , delim: Token.reserved
        *   , shouldStop: int peeker
        *   }
        *   -> (int, {elems: 'a Seq.t, delims: Token.t Seq.t}) parser
        *)
      fun parse_zeroOrMoreDelimitedByReserved
          {parseElem: (int, 'a) parser, delim: Token.reserved, shouldStop}
          i =
        let
          fun loop elems delims i =
            if shouldStop i then
              (i, elems, delims)
            else
              let
                val (i, elem) = parseElem i
                val elems = elem :: elems
              in
                if isReserved delim at i then
                  loop elems (tok i :: delims) (i+1)
                else
                  (i, elems, delims)
              end

          val (i, elems, delims) = loop [] [] i
        in
          ( i
          , { elems = seqFromRevList elems
            , delims = seqFromRevList delims
            }
          )
        end


      (** parse_oneOrMoreDelimitedByReserved
        *   {parseElem: (int, 'a) parser, delim: Token.reserved} ->
        *   (int, {elems: 'a Seq.t, delims: Token.t Seq.t}) parser
        *)
      fun parse_oneOrMoreDelimitedByReserved
          {parseElem: (int, 'a) parser, delim: Token.reserved}
          i =
        let
          fun loop elems delims i =
            let
              val (i, elem) = parseElem i
              val elems = elem :: elems
            in
              if isReserved delim at i then
                loop elems (tok i :: delims) (i+1)
              else
                (i, elems, delims)
            end

          val (i, elems, delims) = loop [] [] i
        in
          ( i
          , { elems = seqFromRevList elems
            , delims = seqFromRevList delims
            }
          )
        end


      (** parse_two:
        *   ('s, 'a) parser * ('s, 'b) parser
        *   -> ('s, ('a * 'b)) parser
        *)
      fun parse_two (p1, p2) state =
        let
          val (state, elem1) = p1 state
          val (state, elem2) = p2 state
        in
          (state, (elem1, elem2))
        end


      (** parse_while:
        *   's peeker -> ('s, 'a) parser -> ('s, 'a Seq.t) parser
        *)
      fun parse_while continue parse state =
        let
          fun loop elems state =
            if not (continue state) then (state, elems) else
            let
              val (state, elem) = parse state
              val elems = elem :: elems
            in
              loop elems state
            end

          val (state, elems) = loop [] state
        in
          (state, seqFromRevList elems)
        end


(*
      (** parse_interleaveWhile
        *   { parseElem: ('s, 'a) parser
        *   , parseDelim: ('s, 'b) parser
        *   , continue: 's peeker
        *   } ->
        *   ('s, {elems: 'a Seq.t, delims: Token.t Seq.t}) parser
        *)
      fun parse_interleaveWhile
          {parseElem: ('s, 'a) parser, parseDelim: ('s, 'b) parser, continue}
          state =
        let
          fun loopElem elems delims state =
            if continue state then (state, elems, delims) else
            let
              val (state, elem) = parseElem state
              val elems = elem :: elems
            in
              loopDelim elems delims state
            end

          and loopDelim elems delims state =
            if continue state then (state, elems, delims) else
            let
              val (state, delim) = parseDelim state
              val delims = delim :: delims
            in
              loopElem elems delims state
            end

          val (state, elems, delims) = loopElem [] [] state
        in
          ( state
          , { elems = seqFromRevList elems
            , delims = seqFromRevList delims
            }
          )
        end
*)

      fun parse_tyvar i =
        if check Token.isTyVar at i then
          (i+1, tok i)
        else
          error
            { pos = Token.getSource (tok i)
            , what = "Expected tyvar."
            , explain = NONE
            }


      fun parse_tyvars i =
        if check Token.isTyVar at i then
          (i+1, Ast.SyntaxSeq.One (tok i))
        else if not (isReserved Token.OpenParen at i
                     andalso check Token.isTyVar at (i+1)) then
          (i, Ast.SyntaxSeq.Empty)
        else
          let
            val (i, openParen) = (i+1, tok i)
            val (i, {elems, delims}) =
              parse_oneOrMoreDelimitedByReserved
                {parseElem = parse_tyvar, delim = Token.Comma}
                i
            val (i, closeParen) =
              parse_reservedToken Token.CloseParen i
          in
            ( i
            , Ast.SyntaxSeq.Many
                { left = openParen
                , right = closeParen
                , elems = elems
                , delims = delims
                }
            )
          end


      fun consume_maybeReserved rc i =
        if isReserved rc at i then
          (i+1, SOME (tok i))
        else
          (i, NONE)

      fun consume_expectReserved rc i =
        if isReserved rc at i then
          (i+1, tok i)
        else
          error
            { pos = Token.getSource (tok i)
            , what =
                "Unexpected token. Expected to see "
                ^ "'" ^ Token.reservedToString rc ^ "'"
            , explain = NONE
            }


      fun check_normalOrOpInfix infdict opp vid =
        if InfixDict.contains infdict vid andalso not (Option.isSome opp) then
          error
            { pos = Token.getSource vid
            , what = "Infix identifier not prefaced by 'op'"
            , explain = NONE
            }
        else
          ()


      fun consume_pat {nonAtomicOkay} infdict i =
        if isReserved Token.Underscore at i then
          ( i+1
          , Ast.Pat.Wild (tok i)
          )
        else if check Token.isPatternConstant at i then
          ( i+1
          , Ast.Pat.Const (tok i)
          )
        else if check Token.isMaybeLongIdentifier at i then
          ( i+1
          , Ast.Pat.Ident
              { opp = NONE
              , id = Ast.MaybeLong.make (tok i)
              }
          )
        else if isReserved Token.OpenParen at i then
          consume_patParensOrTupleOrUnit infdict (tok i) (i+1)
        else if isReserved Token.OpenSquareBracket at i then
          consume_patListLiteral infdict (tok i) (i+1)
        else
          nyi "consume_pat" i


      (** [ ... ]
        *  ^
        *)
      and consume_patListLiteral infdict openBracket i =
        let
          fun finish elems delims closeBracket =
            Ast.Pat.List
              { left = openBracket
              , right = closeBracket
              , elems = elems
              , delims = delims
              }
        in
          if isReserved Token.CloseSquareBracket at i then
            (i+1, finish (Seq.empty ()) (Seq.empty ()) (tok i))
          else
            let
              val parseElem = consume_pat {nonAtomicOkay=true} infdict
              val (i, {elems, delims}) =
                parse_oneOrMoreDelimitedByReserved
                  {parseElem = parseElem, delim = Token.Comma}
                  i
              val (i, closeBracket) =
                consume_expectReserved Token.CloseSquareBracket i
            in
              (i, finish elems delims closeBracket)
            end
        end


      (** ( )
        *  ^
        * OR
        * ( pat )
        *  ^
        * OR
        * ( pat, pat [, pat ...] )
        *  ^
        *)
      and consume_patParensOrTupleOrUnit infdict leftParen i =
        if isReserved Token.CloseParen at i then
          ( i+1
          , Ast.Pat.Unit
              { left = leftParen
              , right = tok i
              }
          )
        else
          let
            val parseElem = consume_pat {nonAtomicOkay=true} infdict
            val (i, {elems, delims}) =
              parse_oneOrMoreDelimitedByReserved
                {parseElem = parseElem, delim = Token.Comma}
                i
            val (i, rightParen) = consume_expectReserved Token.CloseParen i
            val result =
              if Seq.length elems = 1 then
                Ast.Pat.Parens
                  { left = leftParen
                  , pat = Seq.nth elems 0
                  , right = rightParen
                  }
              else
                Ast.Pat.Tuple
                  { left = leftParen
                  , elems = elems
                  , delims = delims
                  , right = rightParen
                  }
          in
            (i, result)
          end


      fun consume_dec infdict i =
        let
          fun consume_maybeSemicolon (i, infdict) =
            if isReserved Token.Semicolon at i then
              ((i+1, infdict), SOME (tok i))
            else
              ((i, infdict), NONE)

          (** While we see a dec-start token, parse pairs of
            *   (dec, semicolon option)
            * The "state" in this computation is a pair (i, infdict), because
            * declarations can affect local infixity.
            *)
          val ((i, infdict), decs) =
            parse_while
              (fn (i, _) => check Token.isDecStartToken at i)
              (parse_two (consume_oneDec, consume_maybeSemicolon))
              (i, infdict)

          fun makeDecMultiple () =
            Ast.Exp.DecMultiple
              { elems = Seq.map #1 decs
              , delims = Seq.map #2 decs
              }

          val result =
            case Seq.length decs of
              0 =>
                Ast.Exp.DecEmpty
            | 1 =>
                let
                  val (dec, semicolon) = Seq.nth decs 0
                in
                  if isSome semicolon then
                    makeDecMultiple ()
                  else
                    dec
                end
            | _ =>
                makeDecMultiple ()
        in
          (i, infdict, result)
        end


      and consume_oneDec (i, infdict) =
        if isReserved Token.Val at i then
          consume_decVal (i+1, infdict)
        else if isReserved Token.Type at i then
          consume_decType (i+1, infdict)
        else if isReserved Token.Infix at i then
          consume_decInfix {isLeft=true} (i+1, infdict)
        else if isReserved Token.Infixr at i then
          consume_decInfix {isLeft=false} (i+1, infdict)
        else if isReserved Token.Nonfix at i then
          consume_decNonfix (i+1, infdict)
        else if isReserved Token.Fun at i then
          consume_decFun (i+1, infdict)
        else
          nyi "consume_oneDec" i


      (** fun tyvarseq [op]vid atpat ... atpat [: ty] = exp [| ...] [and ...]
        *    ^
        *
        * TODO: implement multiple func definitions separated by '|'s, and
        * mutually recursive definitions separated by 'and's.
        *)
      and consume_decFun (i, infdict) =
        let
          val funn = tok (i-1)
          val (i, tyvars) = parse_tyvars i
          val (i, opp) = consume_maybeReserved Token.Op i
          val (i, vid) =
            if check Token.isValueIdentifier at i then
              (i+1, tok i)
            else
              error
                { pos = Token.getSource (tok i)
                , what = "Unexpected token. Expected identifier"
                , explain = NONE
                }

          val _ = check_normalOrOpInfix infdict opp vid

          fun loop acc i =
            if isReserved Token.Colon at i orelse isReserved Token.Equal at i then
              (i, seqFromRevList acc)
            else
              let
                val (i, atpat) = consume_pat {nonAtomicOkay=false} infdict i
              in
                loop (atpat :: acc) i
              end

          val (i, args) = loop [] i

          val (i, ty) =
            if not (isReserved Token.Colon at i) then
              (i, NONE)
            else
              let
                val colon = tok i
                val (i, ty) = consume_ty {permitArrows=true} (i+1)
              in
                (i, SOME {colon = colon, ty = ty})
              end
          val (i, eq) = consume_expectReserved Token.Equal i
          val (i, exp) = consume_exp infdict NoRestriction i

          val fvalbind =
            { delims = Seq.empty ()  (** 'and' delimiters *)
            , elems = Seq.singleton
                { delims = Seq.empty () (** '|' delimiters *)
                , elems = Seq.singleton
                    { opp = opp
                    , id = vid
                    , args = args
                    , ty = ty
                    , eq = eq
                    , exp = exp
                    }
                }
            }
        in
          ( (i, infdict)
          , Ast.Exp.DecFun
              { funn = funn
              , tyvars = tyvars
              , fvalbind = fvalbind
              }
          )
        end


      (** infix [d] vid [vid ...]
        *      ^
        *)
      and consume_decInfix {isLeft} (i, infdict) =
        let
          val infixx = tok (i-1)

          val (i, precedence) =
            if check Token.isDecimalIntegerConstant at i then
              (i+1, SOME (tok i))
            else
              (i, NONE)

          fun loop acc i =
            if check Token.isValueIdentifier at i then
              loop (tok i :: acc) (i+1)
            else
              (i, seqFromRevList acc)

          val (i, elems) = loop [] i

          val result =
            if Seq.length elems = 0 then
              error
                { pos = Token.getSource (tok i)
                , what = "Unexpected token. Missing identifier."
                , explain = NONE
                }
            else if isLeft then
              Ast.Exp.DecInfix
                { infixx = infixx
                , precedence = precedence
                , elems = elems
                }
            else
              Ast.Exp.DecInfixr
                { infixrr = infixx
                , precedence = precedence
                , elems = elems
                }
        in
          ((i, updateInfixDict infdict result), result)
        end


      (** nonfix vid [vid ...]
        *       ^
        *)
      and consume_decNonfix (i, infdict) =
        let
          val nonfixx = tok (i-1)

          fun loop acc i =
            if check Token.isValueIdentifier at i then
              loop (tok i :: acc) (i+1)
            else
              (i, seqFromRevList acc)

          val (i, elems) = loop [] i

          val result =
            if Seq.length elems = 0 then
              error
                { pos = Token.getSource (tok i)
                , what = "Unexpected token. Missing identifier."
                , explain = NONE
                }
            else
              Ast.Exp.DecNonfix
                { nonfixx = nonfixx
                , elems = elems
                }
        in
          ((i, updateInfixDict infdict result), result)
        end


      (** type tyvars tycon = ty
        *     ^
        *
        * TODO: implement possible [and type tyvars tycon = ty and ...]
        *)
      and consume_decType (i, infdict) =
        let
          val typee = tok (i-1)
          val (i, tyvars) = parse_tyvars i
          val (i, tycon) =
            if check Token.isTyCon at i then
              (i+1, tok i)
            else
              error
                { pos = Token.getSource (tok i)
                , what = "Unexpected token. Invalid type constructor."
                , explain = NONE
                }

          val (i, eq) = consume_expectReserved Token.Equal i
          val (i, ty) = consume_ty {permitArrows=true} i

          val typbind =
            { delims = Seq.empty ()
            , elems = Seq.singleton
                { tyvars = tyvars
                , tycon = tycon
                , eq = eq
                , ty = ty
                }
            }
        in
          ( (i, infdict)
          , Ast.Exp.DecType
              { typee = typee
              , typbind = typbind
              }
          )
        end


      (** val tyvarseq [rec] pat = exp [and [rec] pat = exp ...]
        *     ^
        *)
      and consume_decVal (i, infdict) =
        let
          val (i, tyvars) = parse_tyvars i
          val (i, recc) = consume_maybeReserved Token.Rec i
          val (i, pat) = consume_pat {nonAtomicOkay=true} infdict i
          val (i, eq) = consume_expectReserved Token.Equal i
          val (i, exp) = consume_exp infdict NoRestriction i
        in
          ( (i, infdict)
          , Ast.Exp.DecVal
              { vall = tok (i-1)
              , tyvars = tyvars
              , elems = Seq.singleton
                  { recc = recc
                  , pat = pat
                  , eq = eq
                  , exp = exp
                  }
              , delims = Seq.empty ()
              }
          )
        end


      and consume_exp infdict restriction i =
        let
          val (i, exp) =
            if check Token.isConstant at i then
              (i+1, Ast.Exp.Const (tok i))
            else if isReserved Token.OpenParen at i then
              consume_expParensOrTupleOrUnitOrSequence infdict (tok i) (i+1)
            else if isReserved Token.OpenSquareBracket at i then
              consume_expListLiteral infdict (i+1)
            else if isReserved Token.Let at i then
              consume_expLetInEnd infdict (i+1)
            else if isReserved Token.Op at i then
              consume_expValueIdentifier infdict (SOME (tok i)) (i+1)
            else if check Token.isMaybeLongIdentifier at i then
              consume_expValueIdentifier infdict NONE i
            else if isReserved Token.Case at i then
              consume_expCase infdict (i+1)

            else if isReserved Token.Raise at i then
              if anyExpOkay restriction then
                consume_expRaise infdict (i+1)
              else
                error
                  { pos = Token.getSource (tok i)
                  , what = "Unexpected raise exception."
                  , explain = SOME "Try using parentheses: (raise ...)"
                  }

            else if isReserved Token.Fn at i then
              if anyExpOkay restriction then
                consume_expFn infdict (i+1)
              else
                error
                  { pos = Token.getSource (tok i)
                  , what = "Unexpected beginning of anonymous function."
                  , explain = SOME "Try using parentheses: (fn ... => ...)"
                  }

            else
              nyi "consume_exp" i
        in
          consume_afterExp infdict restriction exp i
        end


      (** exp ...
        *    ^
        *
        * Multiple possibilities for what could be found after an expression:
        *   exp : ty              -- type annotation
        *   exp handle ...        -- handle exception
        *   infexp vid infexp     -- infix application
        *   appexp atexp          -- application
        *   exp andalso exp
        *   exp orelse exp
        *
        * Or, to definitely pop back up, we might see
        *   exp )            -- end of parens, tuple, etc.
        *   exp ,            -- continue tuple
        *   exp ;            -- continue sequence
        *   exp |            -- next in match
        *   exp (then|else)  -- if ... then ... else
        *   exp do           -- while ... do ...
        *   exp of           -- case ... of
        *)
      and consume_afterExp infdict restriction exp i =
        let
          val (again, (i, exp)) =
            if
              i >= numToks orelse
              check Token.endsCurrentExp at i
            then
              (false, (i, exp))

            else if
              anyExpOkay restriction
              andalso isReserved Token.Colon at i
            then
              (true, consume_expTyped exp (i+1))

            else if
              anyExpOkay restriction
              andalso isReserved Token.Handle at i
            then
              (true, consume_expHandle infdict exp (i+1))

            else if
              anyExpOkay restriction
              andalso (isReserved Token.Andalso at i
              orelse isReserved Token.Orelse at i)
            then
              (true, consume_expAndalsoOrOrelse infdict exp (i+1))

            else if
              infExpOkay restriction
              andalso Ast.Exp.isInfExp exp
              andalso check Token.isValueIdentifier at i
              andalso InfixDict.contains infdict (tok i)
            then
              (true, consume_expInfix infdict exp (i+1))

            else if
              appExpOkay restriction
            then
              (true, consume_expApp infdict exp i)

            else
              (false, (i, exp))
        in
          if again then
            consume_afterExp infdict restriction exp i
          else
            (i, exp)
        end


      (** [ ... ]
        *  ^
        *)
      and consume_expListLiteral infdict i =
        let
          val openBracket = tok (i-1)

          fun finish elems delims closeBracket =
            Ast.Exp.List
              { left = openBracket
              , right = closeBracket
              , elems = elems
              , delims = delims
              }
        in
          if isReserved Token.CloseSquareBracket at i then
            (i+1, finish (Seq.empty ()) (Seq.empty ()) (tok i))
          else
            let
              val parseElem = consume_exp infdict NoRestriction
              val (i, {elems, delims}) =
                parse_oneOrMoreDelimitedByReserved
                  {parseElem = parseElem, delim = Token.Comma}
                  i
              val (i, closeBracket) =
                consume_expectReserved Token.CloseSquareBracket i
            in
              (i, finish elems delims closeBracket)
            end
        end


      (** case exp of match
        *     ^
        *)
      and consume_expCase infdict i =
        let
          val casee = tok (i-1)
          val (i, exp) = consume_exp infdict NoRestriction i
          val (i, off) = consume_expectReserved Token.Of i
          val (i, {elems, delims}) =
            parse_oneOrMoreDelimitedByReserved
              {parseElem = consume_matchElem infdict, delim = Token.Bar}
              i
        in
          ( i
          , Ast.Exp.Case
              { casee = casee
              , exp = exp
              , off = off
              , elems = elems
              , delims = delims
              }
          )
        end


      (**  pat => exp
        * ^
        *)
      and consume_matchElem infdict i =
        let
          val (i, pat) = consume_pat {nonAtomicOkay=true} infdict i
          val (i, arrow) = consume_expectReserved Token.FatArrow i
          val (i, exp) = consume_exp infdict NoRestriction i
        in
          (i, {pat=pat, arrow=arrow, exp=exp})
        end


      (** fn pat => exp [| pat => exp ...]
        *   ^
        *)
      and consume_expFn infdict i =
        let
          val fnn = tok (i-1)
          val (i, {elems, delims}) =
            parse_oneOrMoreDelimitedByReserved
              {parseElem = consume_matchElem infdict, delim = Token.Bar}
              i
        in
          ( i
          , Ast.Exp.Fn
              { fnn = fnn
              , elems = elems
              , delims = delims
              }
          )
        end


      (** [op] longvid
        *     ^
        *)
      and consume_expValueIdentifier infdict opp i =
        let
          val (i, vid) =
            if check Token.isMaybeLongIdentifier at i then
              (i+1, Ast.MaybeLong.make (tok i))
            else
              error
                { pos = Token.getSource (tok i)
                , what = "Expected value identifier."
                , explain = NONE
                }

          val _ = check_normalOrOpInfix infdict opp (Ast.MaybeLong.getToken vid)
        in
          ( i
          , Ast.Exp.Ident
              { opp = opp
              , id = vid
              }
          )
        end



      (** infexp1 vid infexp2
        *            ^
        *)
      and consume_expInfix infdict exp1 i =
        let
          (* val _ = print ("infix\n") *)

          val id = tok (i-1)
          val (i, exp2) = consume_exp infdict InfExpRestriction i
        in
          ( i
          , makeInfix infdict (exp1, id, exp2)
          )
        end



      (** appexp atexp
        *       ^
        *)
      and consume_expApp infdict leftExp i =
        let
          (* val _ = print ("app\n") *)

          val (i, rightExp) = consume_exp infdict AtExpRestriction i
        in
          ( i
          , Ast.Exp.App
              { left = leftExp
              , right = rightExp
              }
          )
        end


      (** raise exp
        *      ^
        *)
      and consume_expRaise infdict i =
        let
          val raisee = tok (i-1)
          val (i, exp) = consume_exp infdict NoRestriction i

          val result =
            Ast.Exp.Raise
              { raisee = raisee
              , exp = exp
              }

          (** NOTE: this is technically a noop, because `raise` has low enough
            * precedence that the left rotation will never happen. But I like
            * keeping the code here because it's informative.
            *)
          val result = FixExpPrecedence.maybeRotateLeft result
        in
          (i, result)
        end


      (** exp handle ...
        *           ^
        *)
      and consume_expHandle infdict exp i =
        let
          val handlee = tok (i-1)
          val (i, {elems, delims}) =
            parse_oneOrMoreDelimitedByReserved
              {parseElem = consume_matchElem infdict, delim = Token.Bar}
              i

          val result =
            Ast.Exp.Handle
              { exp = exp
              , handlee = handlee
              , elems = elems
              , delims = delims
              }

          val result = FixExpPrecedence.maybeRotateLeft result
        in
          (i, result)
        end



      (** exp1 (andalso|orelse) exp2
        *                      ^
        *)
      and consume_expAndalsoOrOrelse infdict exp1 i =
        let
          val junct = tok (i-1)
          val (i, exp2) = consume_exp infdict NoRestriction i

          val result =
            if Token.isAndalso junct then
              Ast.Exp.Andalso
                { left = exp1
                , andalsoo = junct
                , right = exp2
                }
            else if Token.isOrelse junct then
              Ast.Exp.Orelse
                { left = exp1
                , orelsee = junct
                , right = exp2
                }
            else
              raise Fail "Bug: Parser.parse.consume_expAndalsoOrOrelse"

          val result =
            FixExpPrecedence.maybeRotateLeft result
        in
          (i, result)
        end



      (** exp : ty
        *      ^
        *)
      and consume_expTyped exp i =
        let
          (* val _ = print ("typed\n") *)

          val colon = tok (i-1)
          val (i, ty) = consume_ty {permitArrows=true} i
        in
          ( i
          , Ast.Exp.Typed
              { exp = exp
              , colon = colon
              , ty = ty
              }
          )
        end



      and consume_ty restriction i =
        let
          val (i, ty) =
            if check Token.isTyVar at i then
              ( i+1
              , Ast.Ty.Var (tok i)
              )
            else if isReserved Token.OpenParen at i then
              let
                val leftParen = tok i
                val (i, ty) = consume_ty {permitArrows=true} (i+1)
              in
                consume_tyParensOrSequence leftParen [ty] [] i
              end
            else if check Token.isMaybeLongIdentifier at i then
              ( i+1
              , Ast.Ty.Con
                  { id = Ast.MaybeLong.make (tok i)
                  , args = Ast.SyntaxSeq.Empty
                  }
              )
            else
              nyi "consume_ty" i
        in
          consume_afterTy restriction ty i
        end


      (** ty
        *   ^
        *
        * Multiple possibilities for what could be found after a type:
        *   ty -> ty        -- function type
        *   ty longtycon    -- type constructor
        *   ty * ...        -- tuple
        *)
      and consume_afterTy (restriction as {permitArrows: bool}) ty i =
        let
          val (again, (i, ty)) =
            if check Token.isMaybeLongTyCon at i then
              ( true
              , ( i+1
                , Ast.Ty.Con
                    { id = Ast.MaybeLong.make (tok i)
                    , args = Ast.SyntaxSeq.One ty
                    }
                )
              )
            else if permitArrows andalso isReserved Token.Arrow at i then
              (true, consume_tyArrow ty (i+1))
            else if check Token.isStar at i then
              (true, consume_tyTuple [ty] [] (i+1))
            else
              (false, (i, ty))
        in
          if again then
            consume_afterTy restriction ty i
          else
            (i, ty)
        end



      (** ty -> ty
        *      ^
        *)
      and consume_tyArrow fromTy i =
        let
          val arrow = tok (i-1)
          val (i, toTy) = consume_ty {permitArrows=true} i
        in
          ( i
          , Ast.Ty.Arrow
              { from = fromTy
              , arrow = arrow
              , to = toTy
              }
          )
        end


      (** [... *] ty * ...
        *             ^
        *)
      and consume_tyTuple tys delims i =
        let
          val star = tok (i-1)
          val (i, ty) = consume_ty {permitArrows=false} i
          val tys = ty :: tys
          val delims = star :: delims
        in
          if check Token.isStar at i then
            consume_tyTuple tys delims (i+1)
          else
            ( i
            , Ast.Ty.Tuple
                { elems = seqFromRevList tys
                , delims = seqFromRevList delims
                }
            )
        end


      (** ( ty )
        *     ^
        * OR
        * ( ty [, ty ...] ) longtycon
        *     ^
        *)
      and consume_tyParensOrSequence leftParen tys delims i =
        if isReserved Token.CloseParen at i then
          consume_tyEndParensOrSequence leftParen tys delims (i+1)
        else if isReserved Token.Comma at i then
          let
            val comma = tok i
            val (i, ty) = consume_ty {permitArrows=true} (i+1)
          in
            consume_tyParensOrSequence leftParen (ty :: tys) (comma :: delims) i
          end
        else
          error
            { pos = Token.getSource (tok i)
            , what = "Unexpected token."
            , explain = NONE
            }



      (** ( ty )
        *       ^
        * OR
        * ( ty, ... ) longtycon
        *            ^
        *)
      and consume_tyEndParensOrSequence leftParen tys delims i =
        let
          val rightParen = tok (i-1)
        in
          case (tys, delims) of
            ([ty], []) =>
              ( i
              , Ast.Ty.Parens
                  { left = leftParen
                  , ty = ty
                  , right = rightParen
                  }
              )

          | _ =>
              if check Token.isMaybeLongTyCon at i then
                ( i+1
                , Ast.Ty.Con
                    { id = Ast.MaybeLong.make (tok i)
                    , args =
                        Ast.SyntaxSeq.Many
                          { left = leftParen
                          , elems = seqFromRevList tys
                          , delims = seqFromRevList delims
                          , right = rightParen
                          }
                    }
                )
              else
                error
                  { pos = Token.getSource (tok i)
                  , what = "Unexpected token."
                  , explain = SOME "Expected to see a type constructor."
                  }
        end


      (** let dec in exp [; exp ...] end
        *    ^
        *)
      and consume_expLetInEnd infdict i =
        let
          val lett = tok (i-1)
          val (i, infdict, dec) = consume_dec infdict i
          val (i, inn) = consume_expectReserved Token.In i

          val parseElem = consume_exp infdict NoRestriction
          val (i, {elems, delims}) =
            parse_oneOrMoreDelimitedByReserved
              {parseElem = parseElem, delim = Token.Semicolon}
              i

          val (i, endd) = consume_expectReserved Token.End i
        in
          ( i
          , Ast.Exp.LetInEnd
              { lett = lett
              , dec = dec
              , inn = inn
              , exps = elems
              , delims = delims
              , endd = endd
              }
          )
        end


      (** ( )
        *  ^
        * OR
        * ( exp [, exp ...] )
        *  ^
        * OR
        * ( exp [; exp ...] )
        *  ^
        *)
      and consume_expParensOrTupleOrUnitOrSequence infdict leftParen i =
        if isReserved Token.CloseParen at i then
          ( i+1
          , Ast.Exp.Unit
              { left = leftParen
              , right = tok i
              }
          )
        else
          let
            val parseElem = consume_exp infdict NoRestriction
            val (i, exp) = parseElem i
          in
            if isReserved Token.CloseParen at i then
              ( i+1
              , Ast.Exp.Parens
                  { left = leftParen
                  , exp = exp
                  , right = tok i
                  }
              )
            else
              let
                val delimType =
                  if isReserved Token.Comma at i then
                    Token.Comma
                  else if isReserved Token.Semicolon at i then
                    Token.Semicolon
                  else
                    error
                      { pos = Token.getSource leftParen
                      , what = "Unmatched paren."
                      , explain = NONE
                      }

                val (i, delim) = (i+1, tok i)

                val (i, {elems, delims}) =
                  parse_zeroOrMoreDelimitedByReserved
                    { parseElem = parseElem
                    , delim = delimType
                    , shouldStop = isReserved Token.CloseParen
                    }
                    i

                val (i, rightParen) = consume_expectReserved Token.CloseParen i

                val stuff =
                  { left = leftParen
                  , elems = Seq.append (Seq.singleton exp, elems)
                  , delims = Seq.append (Seq.singleton delim, delims)
                  , right = rightParen
                  }
              in
                case delimType of
                  Token.Comma =>
                    (i, Ast.Exp.Tuple stuff)
                | _ =>
                    (i, Ast.Exp.Sequence stuff)
              end
          end


      val infdict = InfixDict.initialTopLevel
      val (i, _, topdec) = consume_dec infdict 0

      val _ =
        print ("Successfully parsed "
               ^ Int.toString i ^ " out of " ^ Int.toString numToks
               ^ " tokens\n")
    in
      Ast.Dec topdec
    end


end
