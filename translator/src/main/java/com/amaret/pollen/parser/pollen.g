
grammar pollen;
options {
    //backtrack = true;
    language = Java;
    k = 1;
    //memoize = true;
    output = AST;
    ASTLabelType=BaseNode; 
    TokenLabelType=Atom;
}

tokens {
    D_ARG;            // D_ declaration
    D_ARR;
    D_ARR_DIM;
    D_CLASS;
    D_COMPOSITION;
    D_ENUM;
    D_ENUMVAL;    
    D_FCN_CTOR;
    D_FCN_DCL;
    D_FCN_DEF;
    D_FCN_REF;
    D_FCN_TYP_NM;
    D_FORMAL;
    D_FIELD;  
    D_INJ;
    D_INSTANCE; 
    D_META;
    D_MODULE;
    D_PROTOCOL;
    D_VAR;
    
    DELIM;
    E_ADDR;         // E_ expression
    E_BINARY;
    E_CALL;
    E_CONST;
    E_EXPR;
    E_HASH;
    E_IDENT;
    E_INDEX;
    E_INJ;
    E_NEW;
    E_PAREN;
    E_QUEST;
    E_SELF;
    E_TYP;  // synthesized; when I want a type name to be defined by an expr tree
    E_UNARY;
    E_VEC;
    EXPORT;
    FCNBODY;
    HOST;
    IMPORT;
    INJECT;
    LIST;
    MODULE;
    NIL;
    QNAME;
    S_ASSIGN;
    S_BIND;
    S_BLOCK;
    S_BREAK;
    S_CASE;
    S_CONTINUE;
    S_DECL;
    S_ELIF;
    S_EXPR;
    S_FOR;
    S_FOREACH;
    S_IF;
    S_INJ;
    S_PACKAGE;
    S_PEG;
    S_PRINT;
    S_PROVIDED;
    S_RETURN;
    S_SWITCH;
    S_WHILE;
    T_ARR;
    T_LST;
    T_USR;
    T_STD;
    UNIT;
    VOID;
    // rsvd
    THIS = 'this';
}

@parser::header {
    package com.amaret.pollen.parser;
    import java.util.EnumSet;
    import java.util.ArrayList;
    import java.lang.*;
    import java.io.*;
    import com.amaret.pollen.parser.*;
    import com.amaret.pollen.driver.ProcessUnits;
    /**
     * @author lucidbee (Megan Adams)
     */
}
@parser::members {

    private boolean isMetaInstance = false;
    private boolean isVoidInstance = false; // deferred instantiation: '{}'. No code gen.
    private boolean hasHostConstructor = false;  // constructors with 0 parms will by synthesized if not declared.
    private boolean hasTargetConstructor = false;
    private boolean instantiateToDefaults = false; // A meta type imported with no '{..}'
    private UnitNode client = null;
    private ImportNode clientImport = null;
    // Trigger meta instantiation via this constructor
    public pollenParser(TokenStream tokens, UnitNode cl, ImportNode cli) {
        this(tokens, new RecognizerSharedState());
        isMetaInstance = (cl != null && cli != null); 
        client = cl;
        clientImport = cli;
        isVoidInstance = (cli != null && cli.getMeta() != null && cli.getMeta().size() == 0);
        instantiateToDefaults = (cli != null && cli.getMeta() == null);
        ProcessUnits.setPollenProxyBindSeen(ProcessUnits.PollenProtocol.PRINT, false);
        ProcessUnits.setPollenProxyBindSeen(ProcessUnits.PollenProtocol.SLEEP_WAKE, false);
        ProcessUnits.setPollenProxyBindSeen(ProcessUnits.PollenProtocol.DYNAMIC_MEMORY, false);
    }
        
    EnumSet<Flags> featureFlags = EnumSet.noneOf(Flags.class); 
    EnumSet<Flags> metaFlags = EnumSet.noneOf(Flags.class); 
    EnumSet<Flags> stmtFlags = EnumSet.noneOf(Flags.class);
    EnumSet<Flags> typeMods = EnumSet.noneOf(Flags.class);
    
    private class TypeInfo {
        boolean hasHostCtor;
        boolean hasTargCtor;
        private EnumSet<Flags> uf = EnumSet.noneOf(Flags.class);
        private String tn = "";  
        public TypeInfo(boolean hostCtor, boolean targCtor) {
                hasHostCtor = hostCtor;
                hasTargCtor = targCtor;
        }
        public boolean getHostCtor() {
            return hasHostCtor;
        }
        public boolean getTargCtor() {
            return hasTargCtor;
        }
    
        public EnumSet<Flags> getUnitFlags() {
            if (tn.isEmpty()) // backtracking
                return getParseUnitFlags();
            else
                return uf;
        }    
        public void setUnitFlags(EnumSet<Flags> unitFlags) {
            uf.addAll(unitFlags);
        }    
        public String getTypeName() {
            if (tn.isEmpty()) // backtracking
                return getParseUnitTypeName();
            else
                return tn;
        }    
        public void setTypeName(String typeName) {
            this.tn = typeName;
        }    
    
    } // end private class TypeInfo    

    public String getParseUnitTypeName() {
         if (currType == null || typeInfoList.size() <= 0) {
               ParseUnit.current().reportFailure("invalid request");
        }
        String n = typeInfoList.get(typeInfoList.size()-1).getTypeName();
        if (n.isEmpty())
            ParseUnit.current().reportFailure("invalid request");
        return  n;
            
    }
    /**
     *  Use this for DeclNode constructors. 
     */ 
    public EnumSet<Flags> getParseUnitFlags() {
        if (currType == null) {
            ParseUnit.current().reportFailure("invalid request");
        }
        if (typeInfoList.size() <= 0) {
        return EnumSet.noneOf(Flags.class);
        }
        // Get requested flags from type info list, not the current type info object,
        // as the latter can be accessed while backtracking giving invalid flags. 
        TypeInfo ti = typeInfoList.get(typeInfoList.size()-1);
        return ti.getUnitFlags();
    }
    
    private ArrayList<TypeInfo> typeInfoList = new ArrayList<TypeInfo>();
    private TypeInfo currType;

    // currType has info for the type encountered (including while backtracking)
    // but if backtracking don't push currType on the stack.
    // It turns out '@init' code is exec'd when backtracking but '@after' code is not.
    // so this keeps stack integrity. See 
    // http://www.antlr3.org/pipermail/antlr-interest/2010-April/038320.html
    // Perhaps I could avoid this gating if I called these routines in the
    // action not the @init code.
    
    private void pushType() {

      currType = new TypeInfo(hasHostConstructor, hasTargetConstructor);
      // Needs to be gated by backtracking state.
      // If backtracking state > 0 this could be exec'd
      // more than once for a single type.
      if ( state.backtracking==0 ) {
            typeInfoList.add(currType);        
               currType.setUnitFlags(metaFlags); 
               metaFlags = EnumSet.noneOf(Flags.class);        
      }
    }
    private void popType() {
        // currType is on the stack only when we are not backtracking.
        if (typeInfoList.size() <= 0) {
            ParseUnit.current().reportFailure("invalid request");
        }
        if ( state.backtracking==0 ) {
                   currType = typeInfoList.remove(typeInfoList.size()-1); // pop
                   hasHostConstructor = currType.getHostCtor();
                   hasTargetConstructor = currType.getTargCtor();
        }
        if (typeInfoList.size() > 0) {
        currType = typeInfoList.get(typeInfoList.size()-1);
        }
    }
    
    // decode text into literal value for enums. handles hex, octal, decimal, etc. 
    int decode(org.antlr.runtime.CommonToken t) {
            
        try {
            int i = Integer.decode(t.getText());
            if (i < 0)
                ParseUnit.current().reportError(t, "enum values cannot be negative");
            else {
                byte b = (byte) i;
                if (b != i &&  i != 0x80)
                        ParseUnit.current().reportError(t, "enum values must fit in 8 bits");
                }
            return (i & 0xFF);
        } catch (NumberFormatException e) {
            ParseUnit.current().reportError(t, "number format error for enum value " + t.getText());    
            return 0;
        }
    }    
       
    public int getParserTypeInfoListSize() {
        return typeInfoList.size();
    }
    
    String getInject(String text) {
        return text.substring(text.indexOf("+{")+2,text.lastIndexOf("}+"));
    }
    
    void handleIntrinsics(CommonTree t) {
       if (t == null)
           return;
        if (t.getText().indexOf('.') == -1) 
            return;
        char c = t.getText().charAt(0);
        switch (c) {
        case 'p':
            String s = t.getText();             
            if (s.substring(0, s.indexOf('.')).equals("pollen")) {
                s = s.replaceFirst("\\.", "__");
                t.getToken().setText(s);
            }       
            break;
        default:
            break;        
        }    
    }

    
    void DBG(String dbg) {
        System.out.println(dbg);
    }
        /**
         * Synthesize tree to handle qualified pollen names in injected text. 
    * @param root
    * @param inject
    * @return the root of the synthesized tree.
    */
    private BaseNode addInjectChild(BaseNode root, TypedInject inject) {

        root = (root == null) ? (BaseNode)adaptor.nil() : root;
        if (inject.isName()) {
            BaseNode id =  (BaseNode)adaptor.becomeRoot(
                    new ExprNode.Ident(E_IDENT, "E_IDENT")
                    , (BaseNode) adaptor.nil());
            adaptor.addChild(root, id);
            adaptor.addChild(id, 
                    (BaseNode)adaptor.create(pollenParser.IDENT, (inject.getText())));
        }
        else {
            adaptor.addChild(root, 
                    (BaseNode)adaptor.create(INJECT, (inject.getText())));
        }
        root = (BaseNode)adaptor.rulePostProcessing(root);
        return root;
    }
    class TypedInject {
        private boolean isName = false;
        public boolean isName() {
            return isName;
    }
    public String getText() {
            return text;
    }
    private String text = "";
        public TypedInject(String str,boolean name) {
            text = str;
            isName = name;
        }
    }

            /**
             * Split the text that was injected into a list of IDENT and INJECT nodes.
             * The IDENTs will be emitted as pollen names formatted for output.
             * @param root
             * @param inject
             * @return a BaseNode with child nodes for the injects or names in the order encountered.
             */
            public BaseNode createInjectNodes(BaseNode root, String inject) {
                final char BT = '`';
                if (inject.indexOf(BT) == -1) {
                    return addInjectChild(root, new TypedInject(inject, false));
                    
                }
                List<TypedInject> l = new ArrayList<TypedInject>();
                int startBT = 0;
                int endBT = 0;
                String name = "", data = "";
                while (true) {
                    startBT = inject.indexOf(BT);
                    endBT = inject.indexOf(BT, startBT+1);

                    if (startBT > 0) { // data
                        l.add(new TypedInject(inject.substring(0, startBT), false));
                    } 
                    else if (startBT == -1) { // remaining inject is all data
                        endBT = -1;
                        l.add(new TypedInject(inject, false));
                    } 

                    if (endBT == -1)
                        break; 
                    l.add(new TypedInject(inject.substring(startBT+1, endBT), true));// a pollen name
                    inject = inject.substring(endBT+1);
                }
                
                for (TypedInject t : l) {
                    addInjectChild(root, t);
                }
                return root;
            }

    // Override to extract PollenException message when present
    public void displayRecognitionError(String[] tokenNames,
                                        RecognitionException e) {
        String hdr = getErrorHeader(e);
        String msg = getErrorMessage(e, tokenNames);
        if ( e instanceof PollenException) {
                    msg = e.toString();
        }
        hdr = pollenLexer.getFileName()+ ", " + hdr;
        emitErrorMessage(hdr+" "+msg);       
        if (msg.matches(".*mismatched input.*"))
           ParseUnit.current().reportFailure("Illegal program");

        
    }

    String pkgName;
    void DBG_LT() {
      System.out.print("LT: "); 
        if (input.LT(0) != null) System.out.print(input.LT(0).getText() + ", "); 
        if (input.LT(1) != null) System.out.print(input.LT(1).getText() + ", "); 
        if (input.LT(2) != null) System.out.print(input.LT(2).getText() + ", "); 
        System.out.println();
    }
    /** A mismatched char or Token or tree node */
    public class PollenException extends RecognitionException {
        
        String msg;

        public PollenException(String m, IntStream input) {
            super(input);
            msg = m;
        }
        public String toString() {
            return "PollenException(" + msg + ")";
        }
    }
    public class PollenFatalException extends Exception {
        String msg;

        public PollenFatalException(String m) {
            msg = m;
        }
        public String toString() {
            return "PollenFatalException(" + msg + ")";
        }
    }
    public void reportFailure( Exception e )
    {
        ParseUnit.current().reportFailure(e);
    }
}
@lexer::header {
    package com.amaret.pollen.parser;
    import java.util.EnumSet;
    import com.amaret.pollen.parser.Atom;
    /**
     * @author lucidbee (Megan Adams)
     */
    }
@lexer::members {
    private static String fileName = "";
    private int implicitLineJoiningLevel = 0;
    private static int lineNum = 0;
    private int startPos = -1;
    
    public static String getFileName() {
        return fileName;
    }
    public static int getLineNum() {
      return lineNum;
    }
    
     
    pollenLexer( CharStream input, String fileName ) {
        this(input);
        this.fileName = fileName;
    }
    Stack<Integer> braceOpenNLLLineNum = new Stack<Integer>();       
     List tokens = new ArrayList();
        
     public void emit(Token token) {
                state.token = token;
                tokens.add(token);
     }
     @Override
     public Token nextToken() {
            startPos = getCharPositionInLine();
            super.nextToken();
            if ( tokens.size()==0 ) {
                return Token.EOF_TOKEN;
            }
            return (Token)tokens.remove(0);
            //return super.nextToken();
     }

    public Token emit() {
        Atom a = new Atom(
            input,
            state.type,
            state.channel,
            state.tokenStartCharIndex,
            getCharIndex() - 1
        );
        a.setLine(state.tokenStartLine);
        a.setText(state.text);
        a.setCharPositionInLine(state.tokenStartCharPositionInLine);
        a.setFileName(fileName);
        // Synthesized tokens don't have these set:
        pollenLexer.fileName = fileName;
        pollenLexer.lineNum = state.tokenStartLine;
        emit(a);
        return a;
    }

    @Override
    public void reportError( RecognitionException e )
    {
        ParseUnit.current().reportError(e, getErrorMessage(e, getTokenNames()));
    }

}
unit
    :   (NLL)? unitPackage   -> ^(UNIT<UnitNode>["UNIT"] unitPackage)  
    ;
unitPackage
scope {
    Object unitImports;
}
    :              stmtPackage
                   importList {$unitPackage::unitImports = $importList.tree;}                
                   importPrintIntrinsic
                   importSleepWakeIntrinsic
                   importDynamicMemoryIntrinsic
                   stmtInjectionList //  the injects that go into the header file
                   unitTypeDefinition
                   stmtInjectionList
                   NLL?
                   pollenEOF
                       -> stmtPackage importList stmtInjectionList unitTypeDefinition stmtInjectionList 
    ;
pollenEOF
    :    EOF!
    ;
catch [java.lang.ClassCastException e] {
    //ignore: antlr bug
}
stmtInjectionList 
    :(stmtInjection)* -> ^(LIST<ListNode>["LIST"] stmtInjection*)
    ;
stmtPackage
@init {
   String path = ParseUnit.current().getCurrPath();
   String pkg = ParseUnit.mkPackageName(path);
}
    : 'package' qualName NLL  
    {
    		int k = path.lastIndexOf(File.separator);
		int j = path.lastIndexOf(File.separator, k - 1);
		j = j == -1 ? 0 : j + 1;
		String qn = ($qualName.tree != null) ? $qualName.tree.getText() : "";
		boolean isIntrinsic = qn.indexOf('_') != -1 ? qn.substring(0, qn.indexOf('_')).equals("pollen") : false;
		if (!isIntrinsic && !qn.equals(path.substring(j, k))) {
	                    CommonToken t = (CommonToken) ((BaseNode)$qualName.tree).getToken();
                    	        t.setLine(1);
                                ParseUnit.current().reportError(t, 
		         "The name in the package statement ('" + qn + "') must match the current directory name exactly ('"
		         + path.substring(j, k) + "')"); 
		}
		
    }     -> ^(S_PACKAGE[pkg] qualName)
    |     -> ^(S_PACKAGE[pkg]) 
    ;
stmtExport
    :   'export' qualName delim -> ^(EXPORT<ExportNode>["EXPORT"] qualName)
    ;
classDefinition  
@init{
        pushType();
        String qual = "";
        String name = "";
}
@after{
        popType();
}
    :    'class' IDENT
        { 
                  currType.setTypeName($IDENT.text); currType.setUnitFlags(EnumSet.of(Flags.CLASS));
                  if (isMetaInstance && clientImport.getAs() != null && !clientImport.getAs().getText().equals("NIL")) {
                  // if there is an 'as' name in the instantiating context, qualify the unit name 
                  qual = clientImport.getAs().getText();
              }
              name = qual.isEmpty() ? currType.getTypeName() : qual;
          }
           extendsClause
           implementsClause
           braceOpenNLL classFeatureList[name] NLL? braceCloseNLL
           -> ^(D_CLASS<DeclNode.Class>["D_CLASS", getParseUnitFlags(), qual] 
            IDENT classFeatureList extendsClause implementsClause {$unitTypeDefinition::meta})
        ;
classFeatureList[String n]
@init {
  EnumSet<Flags> fh = EnumSet.noneOf(Flags.class);
  fh.add(Flags.CONSTRUCTOR); fh.add(Flags.HOST);
  EnumSet<Flags> ft = EnumSet.noneOf(Flags.class);
  ft.add(Flags.CONSTRUCTOR); 
}
    :    classFeature* classHostCtor[fh] classTargCtor[ft]     intrinsicUnitName[n] intrinsicPrintProxy intrinsicSleepWakeProxy intrinsicDynamicMemoryProxy
            -> ^(LIST<ListNode>["LIST"] 
                                classFeature* 
                                classHostCtor
                                classTargCtor
                                intrinsicUnitName
                                intrinsicPrintProxy
                                intrinsicSleepWakeProxy
                                intrinsicDynamicMemoryProxy)
    ;
classFeature 
@init {
    featureFlags = EnumSet.noneOf(Flags.class);
}
    :   (fcnAttr fcnType formalParameterList NLL? BRACE_OP) => fcnDefinitionVoidOrCtor
    |   (fcnAttr typeName ('[' ']')? qualName  formalParameterList  NLL? BRACE_OP) => fcnDefinition    
    |   (('public')? 'enum') => enumDefinition
    |   fieldDeclaration
    |   classDefinition
    |   injectionDecl
    ; 

classHostCtor[EnumSet<Flags> fh]
@init {
    featureFlags = fh.clone();    
    if (!hasHostConstructor) {
        fh.add(Flags.PUBLIC);
        fh.add(Flags.CONSTRUCTOR);
    }
    
}
    :     {!hasHostConstructor }? ->
            ^(D_FCN_DEF<DeclNode.Fcn>["D_FCN_DEF", fh] 
            ^(D_FCN_CTOR<DeclNode.FcnTyp>["D_FCN_CTOR"] 
                ^(T_LST<TypeNode.Lst>["T_LST", fh] 
                    ^(LIST<ListNode>["LIST"] ^(T_USR<TypeNode.Usr>["T_USR", fh] IDENT[currType.getTypeName()])))                                 
                IDENT[ParseUnit.CTOR_CLASS_HOST]) 
            ^(LIST<ListNode>["LIST"]) // empty parameters
            ^(D_FORMAL<DeclNode.Formal>["D_FORMAL", fh] 
                ^(T_USR<TypeNode.Usr>["T_USR", fh] IDENT[currType.getTypeName()]) 
                    IDENT["this"])
            ^(FCNBODY<BodyNode>["FCNBODY"] ^(LIST<ListNode>["LIST"]) ^(LIST<ListNode>["LIST"]))
            )    
    | -> NIL
    ;
catch [NoViableAltException ne] {
              
        	        if (ne.token.getText().equals("preset")) {
        	        	ParseUnit.current().reportFailure("Preset initializers are only valid in compositions.");
        	        }
        	        else
        	        	throw ne;
        }
classTargCtor[EnumSet<Flags> ft]
@init {
    featureFlags = ft.clone();
    if (!hasTargetConstructor) {
        ft.add(Flags.PUBLIC);
        ft.add(Flags.CONSTRUCTOR);
    }
}
    :    {!hasTargetConstructor}? ->
                ^(D_FCN_DEF<DeclNode.Fcn>["D_FCN_DEF", ft] 
                ^(D_FCN_CTOR<DeclNode.FcnTyp>["D_FCN_CTOR"] 
                    ^(T_LST<TypeNode.Lst>["T_LST", ft] 
                        ^(LIST<ListNode>["LIST"] ^(T_USR<TypeNode.Usr>["T_USR", ft] IDENT[currType.getTypeName()]))) 
                    IDENT[ParseUnit.CTOR_CLASS_TARGET]) 
                ^(LIST<ListNode>["LIST"]) // empty parameters
                ^(D_FORMAL<DeclNode.Formal>["D_FORMAL", ft] 
                    ^(T_USR<TypeNode.Usr>["T_USR", ft] IDENT[currType.getTypeName()]) 
                        IDENT["this"])
                ^(FCNBODY<BodyNode>["FCNBODY"] ^(LIST<ListNode>["LIST"]) ^(LIST<ListNode>["LIST"]))
                )
    |    -> NIL
    ;

moduleDefinition 
scope {
  Object moduleFeatureList;
}
@init{
        pushType();
        String qual = "";
        String name = "";
        hasHostConstructor = false;
        hasTargetConstructor = false;
}
@after{
    popType();
}
    :    'module' IDENT
          { 
              currType.setTypeName($IDENT.text); currType.setUnitFlags(EnumSet.of(Flags.MODULE));
              if (isMetaInstance && clientImport.getAs() != null && !clientImport.getAs().getText().equals("NIL")) {
                  // if there is an 'as' name in the instantiating context, qualify the unit name 
                  qual = clientImport.getAs().getText();
              }
              name = qual.isEmpty() ? currType.getTypeName() : qual;
          }
          extendsClause
          implementsClause
            (NLL)? braceOpenNLL moduleFeatureList[name] (NLL)? braceCloseNLL
            -> ^(D_MODULE<DeclNode.Usr>["D_MODULE", getParseUnitFlags(), qual] 
                IDENT 
                moduleFeatureList //{$moduleDefinition::moduleFeatureList = $moduleFeatureList.tree;}
                extendsClause 
                implementsClause {$unitTypeDefinition::meta}) 
    ;
   
moduleFeatureList[String n]
@init {
      EnumSet<Flags> fh = EnumSet.noneOf(Flags.class);
      fh.add(Flags.CONSTRUCTOR); fh.add(Flags.HOST);
      EnumSet<Flags> ft = EnumSet.noneOf(Flags.class);
      ft.add(Flags.CONSTRUCTOR); 
}
    :    moduleFeature*    moduleHostCtor[fh] moduleTargCtor[ft] intrinsicUnitName[n] intrinsicPrintProxy intrinsicSleepWakeProxy intrinsicDynamicMemoryProxy
            -> ^(LIST<ListNode>["LIST"] 
                moduleFeature* 
                moduleHostCtor 
                moduleTargCtor 
                intrinsicUnitName 
                intrinsicPrintProxy
                intrinsicSleepWakeProxy
                intrinsicDynamicMemoryProxy)
;
intrinsicPrintProxy
@init{
  EnumSet flags;
  if (currType.getUnitFlags().contains(Flags.COMPOSITION)) 
      flags = EnumSet.of(Flags.INTRINSIC_VAR, Flags.HOST, Flags.PROTOCOL_MEMBER) ;
  else
      flags = EnumSet.of(Flags.INTRINSIC_VAR, Flags.PROTOCOL_MEMBER);
}
    :    {ProcessUnits.doEmitPrintProxyViaDashP()}? 
            -> ^(D_VAR<DeclNode.TypedMember>["D_VAR", EnumSet.of(Flags.INTRINSIC_VAR, Flags.BIND, Flags.PROTOCOL_MEMBER)]                 
                ^(T_USR<TypeNode.Usr>["T_USR", EnumSet.of(Flags.INTRINSIC_VAR)] 
                    IDENT[ParseUnit.POLLEN_PRINT_PROTOCOL]
                  ) 
                IDENT[ParseUnit.INTRINSIC_PRINT_PROXY]                 
                 ^( E_TYP<ExprNode.Typ>["E_TYP"]     
                     ^(T_USR<TypeNode.Usr>["T_USR", EnumSet.noneOf(Flags.class)]                                   
                         IDENT[ProcessUnits.getPollenProtocolImpl(ProcessUnits.PollenProtocol.PRINT)]    )                   
                   )
                   )
        |   {ProcessUnits.doEmitProxyViaBind(ProcessUnits.PollenProtocol.PRINT)}? 
            -> ^(D_VAR<DeclNode.TypedMember>["D_VAR", flags]                 
                ^(T_USR<TypeNode.Usr>["T_USR", EnumSet.of(Flags.INTRINSIC_VAR)] 
                    IDENT[ParseUnit.POLLEN_PRINT_PROTOCOL]
                  ) 
                IDENT[ParseUnit.INTRINSIC_PRINT_PROXY]                 
                   )
         | -> NIL    
    ;
intrinsicSleepWakeProxy
@init{
  EnumSet flags;
  if (currType.getUnitFlags().contains(Flags.COMPOSITION)) 
      flags = EnumSet.of(Flags.INTRINSIC_VAR, Flags.HOST, Flags.PROTOCOL_MEMBER) ;
  else
      flags = EnumSet.of(Flags.INTRINSIC_VAR, Flags.PROTOCOL_MEMBER);
}
    :    {ProcessUnits.doEmitProxyViaBind(ProcessUnits.PollenProtocol.SLEEP_WAKE)}? 
            -> ^(D_VAR<DeclNode.TypedMember>["D_VAR", flags]                 
                ^(T_USR<TypeNode.Usr>["T_USR", EnumSet.of(Flags.INTRINSIC_VAR)] 
                    IDENT[ParseUnit.POLLEN_SLEEP_WAKE_PROTOCOL]
                  ) 
                    IDENT[ParseUnit.INTRINSIC_SLEEP_WAKE_PROXY]                 
                   )
         | -> NIL    
    ;
intrinsicDynamicMemoryProxy 
@init{
  EnumSet flags;
  if (currType.getUnitFlags().contains(Flags.COMPOSITION)) 
      flags = EnumSet.of(Flags.INTRINSIC_VAR, Flags.HOST, Flags.PROTOCOL_MEMBER) ;
  else
      flags = EnumSet.of(Flags.INTRINSIC_VAR, Flags.PROTOCOL_MEMBER);
}
    :    {ProcessUnits.doEmitProxyViaBind(ProcessUnits.PollenProtocol.DYNAMIC_MEMORY)}? 
            -> ^(D_VAR<DeclNode.TypedMember>["D_VAR", flags]                 
                ^(T_USR<TypeNode.Usr>["T_USR", EnumSet.of(Flags.INTRINSIC_VAR)] 
                    IDENT[ParseUnit.POLLEN_DYNAMIC_MEMORY_PROTOCOL]
                  ) 
                    IDENT[ParseUnit.INTRINSIC_DYNAMIC_MEMORY_PROXY]                 
                   )
         | -> NIL    
    ;
/*
 * This rule synthesizes a declaration of an intrincsic variable 'unit.name' which holds the name of the unit. 
 * Can add more intrinsic variables in a similar fashion.
 */
intrinsicUnitName[String n]
    :    {true}? -> ^(D_VAR<DeclNode.Var>["D_VAR", EnumSet.of(Flags.INTRINSIC_VAR)] 
                    ^(T_STD<TypeNode.Std>["T_STD", EnumSet.of(Flags.INTRINSIC_VAR)]
                        QNAME["string"]
                      ) 
                    IDENT[ParseUnit.INTRINSIC_UNITVAR] 
                    ^(E_CONST<ExprNode.Const>["E_CONST", EnumSet.of(LitFlags.STR)]
                            STRING["\"" + n + "\""]
                      )
                      )
         | -> NIL                            
    ;
moduleHostCtor[EnumSet<Flags> fh]
@init {
    featureFlags = fh.clone();
}
    :                 {!hasHostConstructor }? ->
                        ^(D_FCN_DEF<DeclNode.Fcn>["D_FCN_DEF", fh] 
                        ^(D_FCN_CTOR<DeclNode.FcnTyp>["D_FCN_CTOR"] 
                            ^(T_LST<TypeNode.Lst>["T_LST", fh] 
                                ^(LIST<ListNode>["LIST"] ^(T_STD<TypeNode.Std>["T_STD", fh] VOID["void"]))) 
                            IDENT[ParseUnit.CTOR_MODULE_HOST]) 
                        ^(LIST<ListNode>["LIST"]) // empty parameters
                        ^(D_FORMAL<DeclNode.Formal>["D_FORMAL", fh] 
                            ^(T_USR<TypeNode.Usr>["T_USR", fh] IDENT[currType.getTypeName()]) IDENT["this"])
                        ^(FCNBODY<BodyNode>["FCNBODY"] ^(LIST<ListNode>["LIST"]) ^(LIST<ListNode>["LIST"]))
                        )    
    | -> NIL
    ;
catch [NoViableAltException ne] {
              
        	        if (ne.token.getText().equals("preset")) {
        	        	ParseUnit.current().reportFailure("Preset initializers are only valid in compositions.");
        	        }
        	        else
        	        	throw ne;
        }
moduleTargCtor[EnumSet<Flags> ft]
@init {
    featureFlags = ft.clone();
}
    :                {!hasTargetConstructor}? ->
                         ^(D_FCN_DEF<DeclNode.Fcn>["D_FCN_DEF", ft] 
                        ^(D_FCN_CTOR<DeclNode.FcnTyp>["D_FCN_CTOR"] 
                            ^(T_LST<TypeNode.Lst>["T_LST", ft] 
                                ^(LIST<ListNode>["LIST"] ^(T_STD<TypeNode.Std>["T_STD", ft] VOID["void"]))) 
                            IDENT[ParseUnit.CTOR_MODULE_TARGET]) 
                        ^(LIST<ListNode>["LIST"]) // empty parameters
                        ^(D_FORMAL<DeclNode.Formal>["D_FORMAL", ft] 
                            ^(T_USR<TypeNode.Usr>["T_USR", ft] 
                                IDENT[currType.getTypeName()]) IDENT["this"])
                        ^(FCNBODY<BodyNode>["FCNBODY"] ^(LIST<ListNode>["LIST"]) ^(LIST<ListNode>["LIST"]))
                        )
    |    -> NIL
    ;
moduleFeature
scope{
    boolean publicEnum;
}
@init {
    featureFlags = EnumSet.noneOf(Flags.class);    
    $moduleFeature::publicEnum = false;
}
       :   (fcnAttr fcnType formalParameterList NLL? BRACE_OP) => fcnDefinitionVoidOrCtor
       |   (fcnAttr typeName ('[' ']')? qualName  formalParameterList  NLL? BRACE_OP) => fcnDefinition
       |   ('new' | 'host' 'new') => varDeclarationNew
       |   varDeclaration 
       |   (('public')? 'enum') => enumDefinition
       |   classDefinition 
       |   injectionDecl 
    ;
 
 
 enumUnitDefinition            // this one does not allow a 'public' attribute (outermost, default is public).
                     // note that when outermost enum did  take optional 'public' it caused some bad parses though no antlr errors.
                     // possibly optional 'public' at the outer level confused the funct / var / type distinction.
 @init{    
     $unitTypeDefinition::publicEnum = false;
 }
     :    'enum'! enumBodyDefinition
     ;
enumDefinition
@init{    
     $unitTypeDefinition::publicEnum = false;
 }
    :    ('public'! { $unitTypeDefinition::publicEnum = true; })?  // will propagate to enum values  
        'enum'!
        enumBodyDefinition
    ;
enumBodyDefinition
scope {
          int val;
}
@init{
        $enumBodyDefinition::val = -1;
        pushType();
        String qual = "";
}
@after{
    popType();
}
    :          (IDENT 
        {           currType.setTypeName($IDENT.text); 
                    currType.setUnitFlags(EnumSet.of(Flags.ENUM));
                    if (typeInfoList.size() == 1 && !(currType.getUnitFlags().contains(Flags.PUBLIC))) {
                        // not nested, must be public
                        currType.setUnitFlags(EnumSet.of(Flags.PUBLIC));
                    }    
                     if ($unitTypeDefinition::publicEnum) {
                        currType.setUnitFlags(EnumSet.of(Flags.PUBLIC));
                    }                                       
            if (isMetaInstance && clientImport.getAs() != null && !clientImport.getAs().getText().equals("NIL")) {
                               // if there is an 'as' name in the instantiating context, qualify the unit name 
                               qual = clientImport.getAs().getText();
                             }
        }
        braceOpenNLL enumList braceCloseNLL)
        -> ^(D_ENUM<DeclNode.Usr>["D_ENUM", getParseUnitFlags(), qual] 
            IDENT enumList {$unitTypeDefinition::meta}) 
    ;
enumList
    :    enumElement 
            (',' (NLL)? enumElement)* NLL? -> ^(LIST<ListNode>["LIST"] enumElement+) 

    ;

// assign defaults for missing values
enumElement
@init {
    String ctext = "";
}
    :     (IDENT ASSIGN)=> IDENT ASSIGN enumVal
        -> ^(D_ENUMVAL<DeclNode.EnumVal>["D_ENUMVAL", getParseUnitFlags()] IDENT enumVal)
    |    IDENT    
            { 
              if ($enumBodyDefinition::val == -1) $enumBodyDefinition::val = 0; 
              ctext = Integer.toString($enumBodyDefinition::val++);
            }
            -> ^(D_ENUMVAL<DeclNode.EnumVal>["D_ENUMVAL", getParseUnitFlags()] IDENT INT_LIT[ctext])
    ;
enumVal
@after {
    $enumBodyDefinition::val++; 
}
    :    INT_LIT  {   $enumBodyDefinition::val = decode($INT_LIT);  }
    |    OCT_LIT  {   $enumBodyDefinition::val = decode($OCT_LIT);  }
    |    HEX_LIT  {   $enumBodyDefinition::val = decode($HEX_LIT);  }
    ;
protocolDefinition
@init{
        pushType();
        String qual = "";
}
@after{
    popType();
}
    :    'protocol' IDENT
        { currType.setTypeName($IDENT.text); currType.setUnitFlags(EnumSet.of(Flags.PROTOCOL));
            if (isMetaInstance && clientImport.getAs() != null && !clientImport.getAs().getText().equals("NIL")) {
                  // if there is an 'as' name in the instantiating context, qualify the unit name 
                      qual = clientImport.getAs().getText();
                  }
        }
        extendsClause
        implementsClause
        (NLL)? braceOpenNLL protocolFeatureList (NLL)? braceCloseNLL 
        -> ^(D_PROTOCOL<DeclNode.Usr>["D_PROTOCOL", getParseUnitFlags(), qual] 
            IDENT protocolFeatureList extendsClause implementsClause {$unitTypeDefinition::meta}) //{$unitTypeDefinition::metaImports})
    ;
protocolFeatureList
    :    protocolFeature*    -> ^(LIST<ListNode>["LIST"] protocolFeature*)
    ;
protocolFeature
@init {
    featureFlags = EnumSet.noneOf(Flags.class);
}
    :   (('public')? 'enum') => enumDefinition
    |   (fcnAttr fcnType formalParameterList delim) => fcnDeclarationVoidOrCtor
    |   fcnDeclaration 
    |   injectionDecl
    ;
compositionDefinition
@init{
        pushType();
        String qual = "";
}
@after{
    popType();
}
    :    'composition' IDENT
        { 
          currType.setTypeName($IDENT.text); 
          currType.setUnitFlags(EnumSet.of(Flags.COMPOSITION));
          if (isMetaInstance && clientImport.getAs() != null && !clientImport.getAs().getText().equals("NIL")) {
              // if there is an 'as' name in the instantiating context, qualify the unit name 
              qual = clientImport.getAs().getText();
          }          
        }
        extendsClause  
        implementsClause
        (NLL)? braceOpenNLL compositionFeatureList (NLL)? braceCloseNLL 
            -> ^(D_COMPOSITION<DeclNode.Usr>["D_COMPOSITION", getParseUnitFlags(), qual] 
                 IDENT compositionFeatureList extendsClause implementsClause {$unitTypeDefinition::meta}) 
    ;
compositionFeatureList
    :    compositionFeature*    
        intrinsicPrintProxy
        intrinsicSleepWakeProxy
        intrinsicDynamicMemoryProxy
        -> ^(LIST<ListNode>["LIST"] compositionFeature* intrinsicPrintProxy intrinsicSleepWakeProxy intrinsicDynamicMemoryProxy)
    ;
compositionFeature
@init {
    featureFlags = EnumSet.noneOf(Flags.class);
    String tn = "";
}
       :  stmtExport     
       |  ('preset') => 'preset' typeName {tn = input.LT(-1).getText();}  formalParameterList fcnBody[$formalParameterList.tree] 
               { 
                  featureFlags.remove(Flags.PUBLIC);
                  featureFlags.add(Flags.HOST);
                  featureFlags.add(Flags.PRESET); 
                  if (!(tn.equals(currType.getTypeName()))) {
                      ParseUnit.current().reportError(currType.getTypeName(), "\'preset\' keyword must be followed by current type name "); 
                  }
               }                    
        -> ^(
                 D_FCN_DEF<DeclNode.Fcn>["D_FCN_DEF", featureFlags]                    
                    ^(D_FCN_TYP_NM<DeclNode.FcnTyp>["D_FCN_TYP_NM"] 
                        ^(T_LST<TypeNode.Lst>["T_LST", featureFlags] 
                              ^(LIST<ListNode>["LIST"] 
                                  ^(T_STD<TypeNode.Std>["T_STD", featureFlags] VOID["void"])
                                 )
                           ) 
                       IDENT[ParseUnit.PRESET_INIT]
                      )                                     
                   formalParameterList 
                   ^(D_FORMAL<DeclNode.Formal>["D_FORMAL", featureFlags] 
                        ^(T_USR<TypeNode.Usr>["T_USR", featureFlags] IDENT[currType.getTypeName()]) 
                         IDENT["this"]
                      )
                  fcnBody
               )
       |  (fcnAttr fcnType formalParameterList NLL? BRACE_OP) => fcnDefinitionVoidOrCtor
       |  (fcnAttr typeName qualName ('[' ']')? formalParameterList  NLL? BRACE_OP) => fcnDefinition     
       |  (('public')? 'enum') => enumDefinition
       |  varDeclaration
       |  injectionDecl
     ; 

stmtImport
scope{
    String qpkg;
    String qimp;
    String asName;
    Object metaArgs;
}
@init{
    String defaultPkg = "";
    String path = this.getTokenStream().getSourceName();
       int k = path.lastIndexOf(File.separator);
       int j = path.lastIndexOf(File.separator, k-1);
       j = j == -1 ? 0 : j+1;
        // the default package is the containing directory
        defaultPkg = path.substring(j, k);
        EnumSet<Flags> importFlags = EnumSet.noneOf(Flags.class);      
}
     :    'from'! importFrom
    
        |    ('import' qualName 
            {    
                if ($qualName.text.equals(ParseUnit.POLLEN_ENVIRONMENT)) {
                    $stmtImport::qimp = ProcessUnits.getPollenEnv();
                    defaultPkg = ProcessUnits.getPollenEnvPkg();
                    importFlags.add(Flags.UNIT_USED);
                    if ($stmtImport::qimp.isEmpty())
                        throw new PollenException("Missing module specification for pollen.environment", input);
                }
                else {
                    $stmtImport::qimp = $qualName.text;
                }
            }  
            (metaArguments { $stmtImport::metaArgs=$metaArguments.tree; })?
             importAs 
             delim) 
              {
                   ParseUnit.current().addToImportsMaps($stmtImport::qimp, $stmtImport::asName, defaultPkg, $stmtImport::metaArgs);
              }
         -> ^(IMPORT<ImportNode>["IMPORT", importFlags] IDENT[defaultPkg] IDENT[$stmtImport::qimp] importAs metaArguments?)
    ;
catch [PollenException re] {
    String hdr = getErrorHeader(re);
    String msg = re.toString();
    emitErrorMessage(hdr+" "+msg);
}


importList
    :      stmtImports //importPrintIntrinsic
    ;

importFrom
@init{
       EnumSet<Flags> importFlags = EnumSet.noneOf(Flags.class);      
}
@after{
    
 }
    
    :       (q1=qualName 
            {    
                $stmtImport::qpkg = ($q1.text.equals(ParseUnit.POLLEN_ENVIRONMENT)) ? ProcessUnits.getPollenEnvPkg() : $q1.text;
                if ($q1.text.equals(ParseUnit.POLLEN_ENVIRONMENT)) {
                    importFlags.add(Flags.UNIT_USED);
                }
                if ($stmtImport::qpkg.isEmpty())
                    throw new PollenException("Missing module specification for pollen.environment", input);
            } 
            'import' 
            q2=qualName 
            {    
                $stmtImport::qimp = ($q2.text.equals(ParseUnit.POLLEN_ENVIRONMENT)) ? ProcessUnits.getPollenEnv() : $q2.text;
                if ($q2.text.equals(ParseUnit.POLLEN_ENVIRONMENT)) {
                    importFlags.add(Flags.UNIT_USED);
                }
                if ($stmtImport::qimp.isEmpty())
                    throw new PollenException("Missing module specification for pollen.environment", input);
            }  
                       (metaArguments { $stmtImport::metaArgs=$metaArguments.tree; })?
                        importAs delim) 
                       {
                             ParseUnit.current().addToImportsMaps($stmtImport::qimp, $stmtImport::asName, $stmtImport::qpkg, $stmtImport::metaArgs);
                       }
         -> ^(IMPORT<ImportNode>["IMPORT", importFlags] IDENT[$stmtImport::qpkg] IDENT[$stmtImport::qimp] importAs metaArguments?)
    
    ;
importAs
    :    'as' q1=qualName 
            { $stmtImport::asName = $q1.text; }
        -> qualName
        
    |    -> NIL
    ;

stmtImports
    :    stmtImport+  -> ^(LIST<ListNode>["LIST"]  stmtImport+)
    |    -> ^(LIST<ListNode>["LIST"] )
    ;
/*
    NOTE first approaches to these rules got a stack overflow in org.antlr.analysis.SemanticContext.
    See notes in Info/info.antlr
    This rule synthesizes AST for intrinsic print when '-p' specifies a print implementation.
    It creates subtrees on empty input which can confuse antlr. Works but extend with care.
*/
importPrintIntrinsic
scope {
    List<Object> l;
}
@init {
    $importPrintIntrinsic::l = new ArrayList<Object>();    
}

@after {
     for (Object o : $importPrintIntrinsic::l) {
         if (o instanceof ImportNode) {
             // add the instantiated import to unit imports
             ((CommonTree) $unitPackage::unitImports).addChild((ImportNode) o);            
         }
     }
}
    :     m1=importPrintImpl      {  $importPrintIntrinsic::l.add($m1.tree);}
         m2=importPrintProtocol    {  $importPrintIntrinsic::l.add($m2.tree);}    
    ;
// synthesize the imports for the print implementation (from the -p option)
importPrintImpl
    :    {ProcessUnits.doImportPollenProtocolImpl(ProcessUnits.PollenProtocol.PRINT)}? 
           -> ^(IMPORT<ImportNode>["IMPORT",  EnumSet.of(Flags.UNIT_USED)] 
            IDENT[ProcessUnits.getPollenProtocolPkg(ProcessUnits.PollenProtocol.PRINT)] 
            IDENT[ProcessUnits.getPollenProtocolImpl(ProcessUnits.PollenProtocol.PRINT)]
            NIL)    
        |  -> NIL
    ;
// To support binding print protocol without requiring -p option we must import the print protocol in every unit
// (except itself). This happens only if -p is NOT used. 
importPrintProtocol
    :    {ProcessUnits.doImportPollenProtocol(ProcessUnits.PollenProtocol.PRINT)}? 
           -> ^(IMPORT<ImportNode>["IMPORT",  (EnumSet.of(Flags.UNIT_USED))] 
            IDENT[ParseUnit.POLLEN_PRINTPKG] 
            IDENT[ParseUnit.POLLEN_PRINT_PROTOCOL]
            NIL)    
        |  -> NIL
    ;
importSleepWakeIntrinsic
scope {
    List<Object> l;
}
@init {
    $importSleepWakeIntrinsic::l = new ArrayList<Object>();    
}

@after {
     for (Object o : $importSleepWakeIntrinsic::l) {
         if (o instanceof ImportNode) {
             // add the instantiated import to unit imports
             ((CommonTree) $unitPackage::unitImports).addChild((ImportNode) o);            
         }
     }
}
    :     
         m1=importSleepWakeProtocol    {  $importSleepWakeIntrinsic::l.add($m1.tree);}    
    ;
// To support binding  protocol anywhere we must import the  protocol in every unit
// (except itself).
importSleepWakeProtocol
    :    {ProcessUnits.doImportPollenProtocol(ProcessUnits.PollenProtocol.SLEEP_WAKE)}? 
           -> ^(IMPORT<ImportNode>["IMPORT",  (EnumSet.of(Flags.UNIT_USED))] 
            IDENT[ParseUnit.POLLEN_SLEEP_WAKE_PKG] 
            IDENT[ParseUnit.POLLEN_SLEEP_WAKE_PROTOCOL]
            NIL)    
        |  -> NIL
    ;
    
importDynamicMemoryIntrinsic
scope {
    List<Object> l;
}
@init {
    $importDynamicMemoryIntrinsic::l = new ArrayList<Object>();
}

@after {
     for (Object o : $importDynamicMemoryIntrinsic::l) {
         if (o instanceof ImportNode) {
             // add the instantiated import to unit imports
             ((CommonTree) $unitPackage::unitImports).addChild((ImportNode) o);            
         }
     }
}
    :     
         m1=importDynamicMemoryProtocol    {  $importDynamicMemoryIntrinsic::l.add($m1.tree);}
    ;
// To support binding  protocol anywhere we must import the  protocol in every unit
// (except itself).
importDynamicMemoryProtocol
    :    {ProcessUnits.doImportPollenProtocol(ProcessUnits.PollenProtocol.DYNAMIC_MEMORY)}?
           -> ^(IMPORT<ImportNode>["IMPORT",  (EnumSet.of(Flags.UNIT_USED))] 
            IDENT[ParseUnit.POLLEN_DYNAMIC_MEMORY_PKG]
            IDENT[ParseUnit.POLLEN_DYNAMIC_MEMORY_PROTOCOL]
            NIL)    
        |  -> NIL
    ;
     
meta 
@init {
}
// Instantiate the meta parameters if this is an instantiation parse.
//    If '{}' is passed, instantiate to defaults.
//    This will be a void instance: no output.
    :    {isMetaInstance}?=> 
            (
            'meta'!    
              { metaFlags.add(Flags.META);}
            ((NLL!)? braceOpenNLL 
                metaParmsGen
              (NLL!)? braceCloseNLL) 
              )    
    |      { isMetaInstance = false;} -> LIST<ListNode>["LIST"]                                        
    ;    
    catch [FailedPredicateException fe] {  
        ParseUnit.current().reportFailure("Missing instantiation. Meta types must be instantiated via the import statement");
    }
metaParmsGen
scope {
    int idx;
    List<Object> l;
}
@init {
    $metaParmsGen::idx = 0;
    $metaParmsGen::l = new ArrayList<Object>();    
}
@after {
     for (Object o : $metaParmsGen::l) {
         if (o instanceof ImportNode) {
             // add the instantiated import to unit imports
             ((CommonTree) $unitPackage::unitImports).addChild((ImportNode) o);            
         }
     }
}
    :    m1=metaParmGen { $metaParmsGen::l.add($m1.tree); } 
        ( ',' 
           (NLL)?  
            m2=metaParmGen { $metaParmsGen::l.add($m2.tree); }
        )*
        -> ^(LIST<ListNode>["LIST"] metaParmGen+)
    ;
  /**************
    To instantiate with type parameters.
    Given:
      package pkgy
      meta {type T} module y 
    if imported as: 
      package pkyz
      from pkgm import modulem
      from pkgy import y{ modulem } as x
    then instantiate as: 
      package pkyz
      from pkgm import modulem as T
      module y
    The 'meta' declaration generates an import 
    when instantiated.
  **************/
metaParmGen 
scope{
    Object  metaArgs;
}
@init {
    // for import stmt 
    String name = "";
    String as = "";
    String from = ""; 
    ExprNode.Const arg = null;    
    EnumSet<Flags> flags = EnumSet.noneOf(Flags.class);        
    String ctext = "";
    EnumSet<LitFlags> lf = EnumSet.noneOf(LitFlags.class);
    if (isVoidInstance) {
        metaFlags.add(Flags.VOID_INSTANCE);
    }

}
@after {
    $metaParmsGen::idx++;

    if ($metaParmGen::metaArgs != null) {
            ((CommonTree) $metaParmGen.tree).addChild(((CommonTree) $metaParmGen::metaArgs));                
              }
}
    :    'type' IDENT ( ASSIGN typeName {name = $typeName.text;})? 
            { 
               flags.add(Flags.TYPE_META_ARG); 
               // get 'as' name
               as = $IDENT.text;
                   // get 'from' pkg
                     for (ImportNode imp: client.getImports()) {
                    if (clientImport.getName().getText().equals(imp.getName().getText())) {
                        from = imp.getFrom().getText();
                        break;
                    }
                }    
                // get import name
                if (instantiateToDefaults || isVoidInstance) {
                    // instantiate to defaults
                    if (name.isEmpty()) {
                        if (isVoidInstance)
                            throw new PollenException("Missing default value. Using \'{}\' to instantiate a meta type requires that the meta type define default values for all meta parameters", input);
                        if (clientImport.getMeta() == null)
                            throw new PollenException("Missing default value. Instantiating a meta type without parameters requires that the meta type define default values for all meta parameters", input);
                    }
                }
                else {
                BaseNode b = (clientImport.getMeta() != null && clientImport.getMeta().size() >= $metaParmsGen::idx+1) 
                        ? clientImport.getMeta().get($metaParmsGen::idx) : null ;
                
                  if (b != null && b.getType() != pollenParser.NIL) { // if false, will use default
                      // get instantiation value
                      
                      if (b instanceof TypeNode.Usr) {
                          name = ((TypeNode.Usr) b).getName().getText();    
                           String handlerName = ""; 
                                           int i = name.indexOf('.');
                                           if (i != -1) { // type is a function ref: "HP.handler"
                                               // handler name ignored for now: look at this if we do it
                                            handlerName = "." + name.substring(i+1);   // the fcn name, 'handler'  
                                            name = name.substring(0, i);  // HP, the unit type                                                                                          
                                            }
                          // fixups
                          String n = ParseUnit.current().getTypeName(client.getQualName(), name);
                          String f = ParseUnit.current().getPackage(client.getQualName(),name);
                          $metaParmGen::metaArgs = (Tree) ParseUnit.current().getMetaArgs(client.getQualName(), name);
                          if (n != null) {
                              name = n;
                              from = f != null ? f : from;                              
                          }        
                      }
                      else if (b instanceof TypeNode.Std) {
                          name = ((TypeNode.Std) b).getIdent().getText();                        
                      }
                      else if (b.getType() == pollenLexer.VOID) // deferred instantiation
                                     name = b.getText();
                      else {
                          throw new PollenFatalException("Meta type parameter requires type to instantiate");
                      }
                  }
                  else {
                     if (name.isEmpty()) { // no default supplied
                           throw new PollenException("Missing actual parameter for meta type instantiation where no default value specified", input);
                     }
                }                    
                }

            }
      -> ^(IMPORT<ImportNode>["IMPORT", flags] IDENT[from] IDENT[name] IDENT[as])

      
     |   builtinType id=IDENT (ASSIGN primitiveLit { ctext = $primitiveLit.text; } )?
             {
             flags.add(Flags.META_ARG);
             if (instantiateToDefaults || isVoidInstance) {
                    // instantiate to defaults
                    if (ctext.isEmpty()) {
                        if (isVoidInstance)
                            throw new PollenException("Using \'{}\' to instantiate a meta type requires default values for all meta parameters", input);
                        if (clientImport.getMeta() == null)
                            throw new PollenException("Instantiating a meta type without parameters requires default values for all meta parameters", input);
                    }
                }
                else {
                  BaseNode b = (clientImport.getMeta() != null && clientImport.getMeta().size() >= $metaParmsGen::idx+1) 
                        ? clientImport.getMeta().get($metaParmsGen::idx) : null ;
                        
                  if (b != null && b.getType() != pollenParser.NIL) { // if false, will use default
                     
                       if (b.getType() != pollenLexer.VOID && !(b instanceof ExprNode.Const)) 
                            throw new PollenFatalException("Invalid meta value parameter specification (must be a constant)");
                         ctext = b.getText();
                     
                       lf = EnumSet.noneOf(LitFlags.class);
                       if (b instanceof ExprNode.Const) {
                           arg = (ExprNode.Const) b;
                           ctext = arg.getValue().getText();
                           EnumSet<LitFlags> formalType = $builtinType.f;
                           lf = arg.getLitFlags();
                           if (!(arg.getLitFlags().contains(LitFlags.NUM) && formalType.contains(LitFlags.NUM))) {
                               if (!(arg.getLitFlags().equals(formalType)))
                                   throw new PollenException("Fomal and actual meta value parameters have inconsistent types", input);             
                           }
                       }
                  }
                  else {
                     if (ctext.isEmpty()) { // no default supplied
                           throw new PollenException("Missing actual parameter for meta type instantiation where no default value specified", input);
                     }
                  }
                     }
             }
        -> ^(D_FORMAL<DeclNode.Formal>["D_FORMAL", flags]  
            ^(T_STD<TypeNode.Std>["T_STD", EnumSet.noneOf(Flags.class)] builtinType) 
                IDENT 
                ^(E_CONST<ExprNode.Const>["E_CONST", lf] IDENT[ctext]))
    ;
catch [PollenFatalException e] {
    ParseUnit.current().reportFailure(e);
}    
metaArguments 
    : (BRACE_OP NLL? BRACE_CL) => BRACE_OP NLL? BRACE_CL    -> ^(LIST<ListNode>["LIST"] NIL) // defer metaArgument binding  
    |  BRACE_OP!  metaArgumentList  BRACE_CL!
    ; 
    // NOTE this rule is peculiar because allowing NLL anywhere in the list as well as optional parameters 
    // is tricky
metaArgumentList //options { backtrack = true; }
   :        metaFirstArg (metaArgument)* 
   		-> ^(LIST<ListNode>["LIST"] metaFirstArg metaArgument*)
   ;
 metaFirstArg
    :	metaArg NLL!?
    |        -> NIL                //  this is a first argument not present (default value used). 
    ;
metaArgument   // arguments after the first are recognized in units of ', NLL? <arg>' 
    :     (metaDelim metaArg) => metaDelim metaArg (NLL!)?
    |     (',' NLL?) => ',' NLL? -> NIL
    ; 
metaDelim
    :	','! NLL!?
    ;
metaArg
    :	primitiveLit
    |       typeNameScalar
    ;
  
typeName
    :    typeNameScalar
    ;
typeNameScalar            // scalar as in 'not array'
    :    builtinType    -> ^(T_STD<TypeNode.Std>["T_STD", typeMods] builtinType)
    |    userTypeName
    ;
userTypeName
    :    qualName    -> ^(T_USR<TypeNode.Usr>["T_USR", typeMods] qualName)
    ;
typeNameArray        
    :    builtinType    -> ^(T_ARR<TypeNode.Arr>["T_ARR", typeMods] ^(T_STD<TypeNode.Std>["T_STD", typeMods] builtinType))
    |    userTypeNameArr
    ;
userTypeNameArr
    :    qualName    -> ^(T_ARR<TypeNode.Arr>["T_ARR", typeMods] ^(T_USR<TypeNode.Usr>["T_USR", typeMods] qualName))
    ;

unitTypeDefinition
scope {
  Object meta;             // specification of meta type/value parameters
  boolean publicEnum;
  }
@after{
   // debug
   if (ParseUnit.isDebugMode())
    System.out.println("       " + currType.getTypeName() + ", " + currType.getUnitFlags().toString());
}
   :   (meta! { $unitTypeDefinition::meta = $meta.tree; })  
       
     (
             ('module') => moduleDefinition           
       |     ('class') =>  classDefinition
       |     ('protocol') => protocolDefinition 
       |     ('composition') => compositionDefinition 
       |     ('enum') => enumUnitDefinition // outermost, not contained
     )
   ;

extendsClause
    :   'extends' qualName
    {
        if (currType.getUnitFlags().contains(Flags.CLASS) || currType.getUnitFlags().contains(Flags.MODULE))
            throw new PollenException("\'extends\' clause is not supported for classes or modules", input);
    }
     -> qualName
    |     -> NIL
    ;

implementsClause
    :   'implements' qualName 
    {
        if (currType.getUnitFlags().contains(Flags.PROTOCOL))
            throw new PollenException("\'implements\' clause is not supported for protocols", input);
        
    }
        -> qualName
    |     -> NIL
    ;
braceCloseNLL
    :    (BRACE_CL NLL) => BRACE_CL! (NLL!)
    |     BRACE_CL!
    ;
catch [NoViableAltException ne] {  
        ParseUnit.current().reportFailure("Invalid token between '{'...'}'. Check that all statements are terminated by a newline or semicolon.");
    }
//braceCloseNLLAtEOF
// the final close brace does not require a delimiter if followed by EOF
// unused.
//   :   (NL!*) BRACE_CL! (NL!)* //(delim)?
//   ;
braceOpenNLL
    :  (BRACE_OP NLL) => BRACE_OP! (NLL!)
    |    BRACE_OP!
    ;
equalityOp
    :    EQ | NOT_EQ
    ;
relationalOp
    :    LT | GT |  LT_EQ  | GT_EQ
    ;
shiftOp
    :    '<<'    |    '>>'
    ;
incDecOp
    : INC | DEC
    ;
addSubOp
    :    PLUS    |    MINUS
    ;
assignOp
    :    ADD_EQ  |  SUB_EQ  |  MUL_EQ  |  DIV_EQ  |  MOD_EQ  |  LSHFT_EQ  |  RSHFT_EQ | BITAND_EQ  |  BITXOR_EQ  |  BITOR_EQ
    ;
multDivModOp
    :    '*'    |    '/'    |    '%'
    ;
logicalNotOp    
    :     LOG_NOT
    ;
bitwiseNotOp    
    :    BIT_NOT
    ;
exprList 
    :    expr (',' expr)*    
        -> ^(LIST<ListNode>["LIST"] expr+)
    |    -> LIST<ListNode>["LIST"]
    ;

expr
   :    exprLogicalOr exprQuestOp[$exprLogicalOr.tree]!
   ;
exprQuestOp[CommonTree expr]
@after {
      if ($exprQuestOp.tree  != null) {
           expr.addChild($exprQuestOp.tree);
      }
}
   :   '?' expr ':' expr ->  ^(E_QUEST<ExprNode.Quest>["E_QUEST"] expr expr)
   |
   ;
exprLogicalOr 
    : (exprLogicalAnd -> exprLogicalAnd)
        (
            '||' exprLogicalAnd
                -> ^(E_BINARY<ExprNode.Binary>["E_BINARY"] '||' $exprLogicalOr exprLogicalAnd)
        )*
    ;
exprLogicalAnd
    :    (exprBitwiseOr    -> exprBitwiseOr)
    (
        '&&' exprBitwiseOr
            -> ^(E_BINARY<ExprNode.Binary>["E_BINARY"] '&&' $exprLogicalAnd exprBitwiseOr)
    )*
    ;
exprBitwiseOr
    :    (exprBitwiseXor -> exprBitwiseXor)
    (
        '|' exprBitwiseXor
        -> ^(E_BINARY<ExprNode.Binary>["E_BINARY"] '|' $exprBitwiseOr exprBitwiseXor)
    )*
    ;
exprBitwiseXor
    :    (exprBitwiseAnd -> exprBitwiseAnd)
    (
        '^' exprBitwiseAnd
        -> ^(E_BINARY<ExprNode.Binary>["E_BINARY"] '^' $exprBitwiseXor exprBitwiseAnd)
    )*
    ;
exprBitwiseAnd
    :    (exprEquality -> exprEquality)
    (
        '&'    exprEquality
        -> ^(E_BINARY<ExprNode.Binary>["E_BINARY"] '&' $exprBitwiseAnd exprEquality)
    )*
    ;
exprEquality
    :    (exprRelational -> exprRelational)
    ( 
        equalityOp exprRelational
        -> ^(E_BINARY<ExprNode.Binary>["E_BINARY"] equalityOp $exprEquality exprRelational)
    )*
    ;
exprRelational
    :    (exprShift -> exprShift)
    ( 
        relationalOp exprShift 
        -> ^(E_BINARY<ExprNode.Binary>["E_BINARY"] relationalOp $exprRelational exprShift)
    )*
    ;
exprShift
    :    (exprAddSub -> exprAddSub)
    ( 
        shiftOp  exprAddSub 
        -> ^(E_BINARY<ExprNode.Binary>["E_BINARY"] shiftOp $exprShift exprAddSub)
    )*
    ;
exprAddSub
    :    (exprMultDiv -> exprMultDiv)
    (
        addSubOp    exprMultDiv
        -> ^(E_BINARY<ExprNode.Binary>["E_BINARY"] addSubOp $exprAddSub exprMultDiv)
        )*
    ;
exprMultDiv
    :    (exprUnary -> exprUnary)
    (
        multDivModOp exprUnary
        -> ^(E_BINARY<ExprNode.Binary>["E_BINARY"] multDivModOp $exprMultDiv exprUnary)
    )*
    ;
exprNew
    //:    'new' typeName fcnArgumentList -> ^(E_NEW<ExprNode.New>["E_NEW"] typeName fcnArgumentList)
@init {
    String ctor = (typeMods.contains(Flags.HOST)) ? ParseUnit.CTOR_CLASS_HOST : ParseUnit.CTOR_CLASS_TARGET;
    if (!(typeMods.contains(Flags.HOST)))
        ctor = (featureFlags.contains(Flags.HOST)) ? ParseUnit.CTOR_CLASS_HOST : ParseUnit.CTOR_CLASS_TARGET;
}
    : 'new' qualName fcnArgumentList fieldOrArrayAccess? 
    -> ^(E_NEW<ExprNode.New>["E_NEW"] 
            ^(E_CALL<ExprNode.Call>["E_CALL"] 
            ^(E_IDENT<ExprNode.Ident>["E_IDENT"] IDENT[$qualName.text + "." + ctor]) fcnArgumentList fieldOrArrayAccess?))
    ;

exprUnary
    :    injectionCode
 //   |    arrayLit                -> ^(E_VEC<ExprNode.Vec>["E_VEC"] arrayLit) deleted because unused
    |    logicalNotOp exprPrimary             -> ^(E_UNARY<ExprNode.Unary>["E_UNARY"]  exprPrimary logicalNotOp)
    |    bitwiseNotOp exprPrimary              -> ^(E_UNARY<ExprNode.Unary>["E_UNARY"]  exprPrimary bitwiseNotOp)
    |    MINUS exprPrimary               -> ^(E_UNARY<ExprNode.Unary>["E_UNARY"]  exprPrimary MINUS)
    |    incDecOp exprPrimary         -> ^(E_UNARY<ExprNode.Unary>["E_UNARY"] exprPrimary incDecOp)
 //   |    exprNew can get this via varOrFcnorArray
    |    (varOrFcnOrArray incDecOp) => exprPrimary incDecOp 
         -> ^(E_UNARY<ExprNode.Unary>["E_UNARY", true] exprPrimary incDecOp)
    |    exprPrimary
    ;
exprPrimary
    :    primitiveLit
    |    '(' expr ')'                -> ^(E_PAREN<ExprNode.Paren>["E_PAREN"]  expr)
    |    varOrFcnOrArray
    ;
 
fcnDefinition

    : fcnAttr fcnType_fcnName formalParameterList fcnBody[$formalParameterList.tree] 
            {     
                if (currType.getUnitFlags().contains(Flags.COMPOSITION)) {
                    featureFlags.add(Flags.PUBLIC); /* enforce */     
                    if (!featureFlags.contains(Flags.HOST))
                       throw new PollenException("Composition features must be one of host or preset functions, export statements, or enum definitions.", input);
                }
            }        
        -> ^(D_FCN_DEF<DeclNode.Fcn>["D_FCN_DEF", featureFlags] 
            fcnType_fcnName 
            formalParameterList         

            ^(D_FORMAL<DeclNode.Formal>["D_FORMAL", featureFlags] 
                ^(T_USR<TypeNode.Usr>["T_USR", featureFlags] IDENT[currType.getTypeName()]) IDENT["this"])
            fcnBody
        )
    ;
catch [PollenException re] {
    String hdr = getErrorHeader(re);
    String msg = re.toString();
    emitErrorMessage(hdr+" "+msg);
}

fcnDefinitionVoidOrCtor

    : fcnAttr fcnType formalParameterList fcnBody[$formalParameterList.tree] 
    
           {     
                if (currType.getUnitFlags().contains(Flags.COMPOSITION)) {
                    featureFlags.add(Flags.PUBLIC); /* enforce */     
                    if (!featureFlags.contains(Flags.HOST))
                       throw new PollenException("Composition features must be one of host functions, a preset initializer, export statements, or enum definitions.", input);
                }
            }
        
        -> ^(D_FCN_DEF<DeclNode.Fcn>["D_FCN_DEF", featureFlags] 
            fcnType
            formalParameterList         
            ^(D_FORMAL<DeclNode.Formal>["D_FORMAL", featureFlags] 
                ^(T_USR<TypeNode.Usr>["T_USR", featureFlags] IDENT[currType.getTypeName()]) IDENT["this"])
            fcnBody
        )
    ;
catch [PollenException re] {
    String hdr = getErrorHeader(re);
    String msg = re.toString();
    emitErrorMessage(hdr+" "+msg);
}
    
fcnAttr
    :   (    'public' { featureFlags.add(Flags.PUBLIC); } 
        |    'host' { featureFlags.add(Flags.HOST); } 
        )*
    ;
fcnBody[CommonTree formals]
  :    (NLL)? braceOpenNLL (stmts)  braceCloseNLL  -> ^(FCNBODY<BodyNode>["FCNBODY"] {$formals} stmts) 
  ;

fcnDeclarationVoidOrCtor

   :    fcnAttr fcnType (formalParameterList) delim
        {
            if (currType.getUnitFlags().contains(Flags.PROTOCOL))
                featureFlags.add(Flags.PUBLIC);
        }
   -> ^(D_FCN_DCL<DeclNode.Fcn>["D_FCN_DCL", featureFlags] 
           fcnType
           formalParameterList 
         ^(D_FORMAL<DeclNode.Formal>["D_FORMAL", featureFlags] 
            ^(T_USR<TypeNode.Usr>["T_USR", featureFlags] IDENT[currType.getTypeName()]) IDENT["this"])
       )
   ;

fcnType
@init{
    String modCtor = "";
    String clsCtor = "";
}
    :    {input.LT(1).getText().equals(currType.getTypeName()) && !(currType.getUnitFlags().contains(Flags.CLASS)) }?=>
        typeName             
        { 
          featureFlags.add(Flags.CONSTRUCTOR); 
          if (featureFlags.contains(Flags.HOST)) hasHostConstructor = true;
          if (!featureFlags.contains(Flags.HOST)) hasTargetConstructor = true;
          modCtor = (featureFlags.contains(Flags.HOST)) ? ParseUnit.CTOR_MODULE_HOST : ParseUnit.CTOR_MODULE_TARGET;
        }
        -> ^(D_FCN_CTOR<DeclNode.FcnTyp>["D_FCN_CTOR"] 
            ^(T_LST<TypeNode.Lst>["T_LST", featureFlags] 
            ^(LIST<ListNode>["LIST"] ^(T_STD<TypeNode.Std>["T_STD", featureFlags] VOID["void"]))) 
            IDENT[modCtor])           
    |    {input.LT(1).getText().equals(currType.getTypeName()) }?=> // Class constructor
        typeName     
        { 
          featureFlags.add(Flags.CONSTRUCTOR); 
          if (featureFlags.contains(Flags.HOST)) hasHostConstructor = true;
          if (!featureFlags.contains(Flags.HOST)) hasTargetConstructor = true;
          clsCtor = (featureFlags.contains(Flags.HOST)) ? ParseUnit.CTOR_CLASS_HOST : ParseUnit.CTOR_CLASS_TARGET;
        }
        -> ^(D_FCN_CTOR<DeclNode.FcnTyp>["D_FCN_CTOR"] 
            ^(T_LST<TypeNode.Lst>["T_LST", featureFlags] 
            ^(LIST<ListNode>["LIST"] typeName)) IDENT[clsCtor])           // constructor
    |    qualName     
        { featureFlags.add(Flags.VOID_FCN); }
        -> ^(D_FCN_TYP_NM<DeclNode.FcnTyp>["D_FCN_TYP_NM"] ^(T_LST<TypeNode.Lst>["T_LST", featureFlags] 
                ^(LIST<ListNode>["LIST"] ^(T_STD<TypeNode.Std>["T_STD", featureFlags] VOID["void"]))) qualName)      //  returns void
    ;
fcnDeclaration
   :    fcnAttr
        fcnType_fcnName (formalParameterList) delim
        {
            if (currType.getUnitFlags().contains(Flags.PROTOCOL))
                featureFlags.add(Flags.PUBLIC);
        }
   -> ^(D_FCN_DCL<DeclNode.Fcn>["D_FCN_DCL", featureFlags] 
           fcnType_fcnName 
           formalParameterList 
         ^(D_FORMAL<DeclNode.Formal>["D_FORMAL", featureFlags] 
            ^(T_USR<TypeNode.Usr>["T_USR", featureFlags] IDENT[currType.getTypeName()]) IDENT["this"])
       )
   ;

fcnType_fcnName
// function names in a dcln can be qualified, e.g. pollen.reset()
// function return is always a list, empty for void fcn.
// module constructors have the name "targetInit" or "$$hostInit", class constructors have the name "new"
    :   (typeNameArray '[') =>  typeNameArray varArraySpec qualName
        -> ^(D_FCN_TYP_NM<DeclNode.FcnTyp>["D_FCN_TYP_NM"]  
            ^(T_LST<TypeNode.Lst>["T_LST", featureFlags] 
                ^(LIST<ListNode>["LIST"] typeNameArray)) 
                qualName)   
    |    typeName qualName  
        -> ^(D_FCN_TYP_NM<DeclNode.FcnTyp>["D_FCN_TYP_NM"]  
            ^(T_LST<TypeNode.Lst>["T_LST", featureFlags] 
                ^(LIST<ListNode>["LIST"] typeName)) 
                qualName)      // int myfcn()

    ;
    
 /*
    This rule alternative from fcnType_fcnName is now commented out because it conflicts with dcln of function references. 
    Since we don't implement multiple function returns, I've commented it and related rules out. 
    |    ('(' typeName (',' typeName)* ')' qualName) => fcnTypes_fcnName    // multiple returns
fcnTypes_fcnName
    :    '(' fcnTypes ')' qualName -> ^(D_FCN_TYP_NM<DeclNode.FcnTyp>["D_FCN_TYP_NM"]  fcnTypes qualName)
    ;
fcnTypes
    :    typeName (',' typeName)* -> ^(T_LST<TypeNode.Lst>["T_LST", featureFlags] ^(LIST<ListNode>["LIST"] typeName+))
    ;
*/
    
formalParameterList
    :    '(' formalParameters ')' -> formalParameters
    ;

// class methods (except host methods) will pass a ptr to their struct 
// as a first parameter: implementation of 'this' ptr. This is added to 'c' and is not a 
// part of the internal signature. 

formalParameters
@init {
}
    :    formalParameter (NLL? ',' NLL? formalParameter)*  
        -> ^(LIST<ListNode>["LIST"] formalParameter+)
    |    
        -> ^(LIST<ListNode>["LIST"])
    ;

formalParameter
@init {
    EnumSet<Flags> pFlags = EnumSet.noneOf(Flags.class);        
}
    :      'type' IDENT ( ASSIGN t=typeName)?
            { pFlags.add(Flags.TYPE_META_ARG); } // meta formal arguments only
            -> ^(D_FORMAL<DeclNode.Formal>["D_FORMAL", pFlags] 
                ^(T_USR<TypeNode.Usr>["T_USR", pFlags] IDENT) 
                IDENT ^(E_TYP<ExprNode.Typ>["E_TYP"] typeName)?)
    |      (typeName  '[') => formalParameterArr
    |       typeName IDENT ( ASSIGN expr)?
            -> ^(D_FORMAL<DeclNode.Formal>["D_FORMAL"] typeName IDENT (expr)?)

    ;
formalParameterArr
    :    typeNameArray '[' ']' IDENT ( ASSIGN expr)?
            -> ^(D_FORMAL<DeclNode.Formal>["D_FORMAL"] typeNameArray IDENT (expr)?)
    ;
fcnArgumentList
    :    '(' fcnArguments ')'    ->  fcnArguments
    ;
fcnArguments
    :    exprList
    ;
varOrFcnOrArray
 //   :    exprNew 
    :   ('@' IDENT '(') =>  '@' IDENT fcnArgumentList fieldOrArrayAccess? 
        -> ^(E_SELF<ExprNode.Self>["E_SELF"] 
            ^(E_CALL<ExprNode.Call>["E_CALL"] ^(E_IDENT<ExprNode.Ident>["E_IDENT"] IDENT) fcnArgumentList fieldOrArrayAccess?))
           
    |     ('@' IDENT) =>'@'    IDENT fieldOrArrayAccess?       
        -> ^(E_SELF<ExprNode.Self>["E_SELF"] ^(E_IDENT<ExprNode.Ident>["E_IDENT"] IDENT fieldOrArrayAccess?))
        
    |    '@'    
        -> ^(E_SELF<ExprNode.Self>["E_SELF"]  ^(E_IDENT<ExprNode.Ident>["E_IDENT"] IDENT["this"])) 
     // NOTE the order and structure of these rules reflects the tree we want which is a flat branch for all post expressions.
     |    (qualName '(') => qualName fcnArgumentList  fieldOrArrayAccess?
            -> ^(E_CALL<ExprNode.Call>["E_CALL"] ^(E_IDENT<ExprNode.Ident>["E_IDENT"] qualName) fcnArgumentList fieldOrArrayAccess?)
     |    (qualName '[') => qualName arrayAccess fcnArgumentList? fieldOrArrayAccess?
            -> ^(E_IDENT<ExprNode.Ident>["E_IDENT"] qualName arrayAccess fcnArgumentList? fieldOrArrayAccess?) 
     |     qualName 
            -> ^(E_IDENT<ExprNode.Ident>["E_IDENT"] qualName)
    ;

fieldOrArrayAccess
// the function arg list is for arrays of function references
    :     (fieldAccess | arrayAccess fcnArgumentList?)+
    ;
fieldAccess
    :    ('.'    IDENT '(') => '.'    IDENT fcnArgumentList    
            -> ^(E_CALL<ExprNode.Call>["E_CALL", true] 
             ^(E_IDENT<ExprNode.Ident>["E_IDENT"] IDENT)  fcnArgumentList)
    |    '.'    IDENT     -> ^(E_IDENT<ExprNode.Ident>["E_IDENT", true] IDENT)
    ;
arrayAccess
    :    '['    (exprList)    ']'  
           -> ^(E_INDEX<ExprNode.Index>["E_INDEX"] exprList ) 
    ;
    
    
stmtBlock
    :     braceOpenNLL stmts braceCloseNLL     -> ^(S_BLOCK<StmtNode.Block>["S_BLOCK"] stmts)
    ;
stmts
    :    (stmt)+ -> ^(LIST<ListNode>["LIST"] stmt+) 
    |     -> LIST<ListNode>["LIST"]
    ;
stmt
@init {
    typeMods = EnumSet.noneOf(Flags.class);
    stmtFlags = EnumSet.noneOf(Flags.class);
}
    :    ( INJECT assign) => stmtAssignInject
    |    ( INJECT) => stmtInjection
    |    stmtBlock
    |    stmtPrint
    |    stmtReturn
    |    stmtBreak
    |    stmtContinue
    |    stmtFor
    |    stmtSwitch 
    |    stmtDoWhile
    |    stmtIf
    |    stmtProvided
    |    stmtWhile 
    |    ('const' | 'volatile' | 'host') => stmtDecl 
    |    ( varDecl delim) => stmtDecl 
    |    ( varOrFcnOrArray assign) => stmtAssignVar
    |    ( qualName BIND) => stmtBind
    |    (varOrFcnOrArray  PEG) => stmtPeg 
    |     ('new' | 'host' 'new') => varDeclarationNew
    |    exprUnary delim  -> ^(S_EXPR<StmtNode.Expr>["S_EXPR"] exprUnary)
    ;
    
    // Note I had to take 'exprNew' out of exprUnary because it was both an expr in expr grammar and a stmt. 
    // stmt alloiws expr as well as 'new' as a standalone statement and this was ambiguous in the stmt rule. 
    // Here it is not accessible from expr. 
exprAssign
    :    
    (exprUnary ASSIGN ) => exprChainedAssign
    | ('new') => exprNew
    | expr
    ;
exprChainedAssign
    :    ( exprUnary ASSIGN exprAssign 
        -> ^(E_BINARY<ExprNode.Binary>["E_BINARY"] ASSIGN exprUnary  exprAssign)
        )
    ;
    
stmtAssignVar
    :    varOrFcnOrArray assign exprAssign delim
        -> ^(S_ASSIGN<StmtNode.Assign>["S_ASSIGN"] ^(E_BINARY<ExprNode.Binary>["E_BINARY", true] assign varOrFcnOrArray exprAssign))
    ;
stmtAssignInject
    :	injectionCode assign expr delim
        -> ^(S_ASSIGN<StmtNode.Assign>["S_ASSIGN"] ^(E_BINARY<ExprNode.Binary>["E_BINARY", true] assign injectionCode expr))
    ;
assign
    :		ASSIGN | assignOp
    ;
stmtBind
@init{
    String qn = "";
}
    :    ( qualName BIND)  => qualName BIND  userTypeName     delim 
        {

            if ($qualName.text.equals(ParseUnit.POLLEN_PRINT_PROXY)) {
            
                       if (ProcessUnits.isDashPoption()) {
                           ParseUnit.current().
                           reportError(ParseUnit.POLLEN_PRINT_PROXY, 
                           "Either the '-p' option to bind a print protocol can be used or a print protocol can be bound in code - but both cannot be used at once");
                       }
                       if (getParserTypeInfoListSize() > 1) {
                           ParseUnit.current().reportError(ParseUnit.POLLEN_PRINT_PROXY, "Invalid bind of protocol member: not allowed in nested class");
                       }
                               
                qn = ParseUnit.INTRINSIC_PRINT_PROXY;
                ProcessUnits.setPollenProxyBindSeen(ProcessUnits.PollenProtocol.PRINT, true); // causes the  protocol member to be created
                ProcessUnits.setPollenProtocolImpl(ProcessUnits.PollenProtocol.PRINT, $userTypeName.text);
                ProcessUnits.setPollenProxyModule(ProcessUnits.PollenProtocol.PRINT,ParseUnit.mkPackageName(ParseUnit.current().getCurrPath()) + "."  + currType.getTypeName());
                
            }
            else if ($qualName.text.equals(ParseUnit.POLLEN_DYNAMIC_MEMORY_PROXY)) {
            
                       if (getParserTypeInfoListSize() > 1) {
                           ParseUnit.current().reportError(ParseUnit.POLLEN_DYNAMIC_MEMORY_PROXY, "Invalid bind of protocol member: not allowed in nested class");
                       }
                               
                qn = ParseUnit.INTRINSIC_DYNAMIC_MEMORY_PROXY;
                ProcessUnits.setPollenProxyBindSeen(ProcessUnits.PollenProtocol.DYNAMIC_MEMORY, true); // causes the  protocol member to be created
                ProcessUnits.setPollenProtocolImpl(ProcessUnits.PollenProtocol.DYNAMIC_MEMORY, $userTypeName.text);
                ProcessUnits.setPollenProxyModule(ProcessUnits.PollenProtocol.DYNAMIC_MEMORY, ParseUnit.mkPackageName(ParseUnit.current().getCurrPath()) + "."  + currType.getTypeName());
                
            }
            else if ($qualName.text.equals(ParseUnit.POLLEN_SLEEP_WAKE_PROXY)) {
            
                       if (getParserTypeInfoListSize() > 1) {
                           ParseUnit.current().reportError(ParseUnit.POLLEN_SLEEP_WAKE_PROXY, "Invalid bind of protocol member: not allowed in nested class");
                       }
                               
                qn = ParseUnit.INTRINSIC_SLEEP_WAKE_PROXY;
                ProcessUnits.setPollenProxyBindSeen(ProcessUnits.PollenProtocol.SLEEP_WAKE, true); // causes the  protocol member to be created
                ProcessUnits.setPollenProtocolImpl(ProcessUnits.PollenProtocol.SLEEP_WAKE, $userTypeName.text);
                ProcessUnits.setPollenProxyModule(ProcessUnits.PollenProtocol.SLEEP_WAKE, ParseUnit.mkPackageName(ParseUnit.current().getCurrPath()) + "."  + currType.getTypeName());
                
            }
            else
                qn = $qualName.text;
        }    
            -> ^(S_BIND<StmtNode.Bind>["S_BIND"] ^(E_IDENT<ExprNode.Ident>["E_IDENT"] IDENT[qn])  userTypeName)    
    ;
stmtPeg
    :    varOrFcnOrArray  PEG  exprAssign     delim -> ^(S_PEG<StmtNode.Peg>["S_PEG"] varOrFcnOrArray  PEG exprAssign)    
    ;
printList    
    :        printItemList    -> ^(LIST<ListNode>["LIST"] printItemList)
    ;
printItemList
    :    printItem    ( PLUS printItem) *    -> printItem+
    |    -> NIL
    ;
printItem
    :    primitiveLit    
    |    varOrFcnOrArray
    ;
stmtPrint
@init {
    EnumSet<Flags> flags = EnumSet.noneOf(Flags.class);
}
    :	    'print' (stmtPrintTarget[flags]) printList delim
                  -> ^(S_PRINT<StmtNode.Print>["S_PRINT", flags] printList) 
    ;
stmtPrintTarget[EnumSet<Flags> f]
    :    
        (         'log'  {f.add(Flags.LOG); }
                | 'err'    {f.add(Flags.ERR); }
                | 'out'  {f.add(Flags.OUT); }
                |   {f.add(Flags.OUT); }
        )
    ;
stmtReturn
// Note multiple return values not implemented but the single value
// is returned in a vector.
    :	'return'  
                 (
                   ((expr)  delim   
                       -> ^(S_RETURN<StmtNode.Return>["S_RETURN"] ^(E_VEC<ExprNode.Vec>["E_VEC"] ^(LIST<ListNode>["LIST"] expr)))
                   )
                 | (delim
                       -> ^(S_RETURN<StmtNode.Return>["S_RETURN"])
                   )
                 )
	;
stmtBreak
    :    'break' delim -> ^(S_BREAK<StmtNode.Break>["S_BREAK"])
    ;
stmtContinue
    :    'continue' delim -> ^(S_CONTINUE<StmtNode.Continue>["S_CONTINUE"])
    ;
stmtFor
    :   'for' defaultLoopVar stmtForInit stmtForCond stmtForNext ')' (NLL)? stmtBlock
            -> ^(S_FOR<StmtNode.For>["S_FOR"]  stmtForInit stmtForCond stmtForNext stmtBlock defaultLoopVar)
    ;
stmtForCond
    :   SEMI
           -> NIL
    |   expr SEMI -> expr
    ;
defaultLoopVar   // subtree to use if no loop var is declared
    :    lv='(' -> ^(S_DECL<StmtNode.Decl>["S_DECL"] 
                 ^(D_VAR<DeclNode.Var>["D_VAR", EnumSet.noneOf(Flags.class)] 
                     ^(T_STD<TypeNode.Std>["T_STD", EnumSet.noneOf(Flags.class)] IDENT[$lv,"uint32"]) 
                     IDENT[ParseUnit.DEFAULT_LOOPVAR]  ))
    ;

stmtForInit
    :   SEMI
            -> NIL
    |   (typeName IDENT ASSIGN) => typeName IDENT ASSIGN expr SEMI
            -> ^(S_DECL<StmtNode.Decl>["S_DECL"] 
                 ^(D_VAR<DeclNode.Var>["D_VAR", EnumSet.noneOf(Flags.class)] typeName IDENT expr))
    |   (INJECT) => stmtAssignInject
    |    stmtAssignVar
    ;
stmtForNext
    :   //empty
            -> NIL
    |   expr
    ;
    /*
    Implement after collections are available.
stmtForEach
    :    'foreach' '(' IDENT 'in' expr ')' stmtBlock -> ^(S_FOREACH IDENT ^(E_IDENT expr) stmtBlock)
    ;
    */
stmtSwitch
    :    'switch' '(' expr ')' (NLL)? braceOpenNLL stmtsCase stmtDefault? braceCloseNLL    -> ^(S_SWITCH<StmtNode.Switch>["S_SWITCH"]  expr stmtsCase stmtDefault?)
    ;
stmtsCase
    :    stmtCase* -> ^(LIST<ListNode>["LIST"] stmtCase*)
    ;
stmtDefault
    :    'default'    ':' (NLL)? stmts    -> ^(S_CASE<StmtNode.Case>["S_CASE"] stmts)
    ;
stmtCase
@init {
    EnumSet<LitFlags> litFlags = EnumSet.of(LitFlags.INT);
}
    :    ('case' INT_LIT) =>'case' (INT_LIT)    ':' (NLL)? stmts    -> ^(S_CASE<StmtNode.Case>["S_CASE"] stmts 
                                ^(E_CONST<ExprNode.Const>["E_CONST", litFlags] INT_LIT))
    |    'case' (qualName)    ':' (NLL)? stmts    -> ^(S_CASE<StmtNode.Case>["S_CASE"] stmts 
                                ^(E_IDENT<ExprNode.Ident>["E_IDENT"] IDENT[$qualName.text])) // enum val
    ;
stmtDoWhile
    :    'do' (NLL)? stmtBlock 'while' '(' expr ')' delim     -> ^(S_WHILE<StmtNode.While>["S_WHILE", true] expr stmtBlock)
    ;
stmtIf
    :    'if' stmtIfBlock stmtsElif stmtElse?    -> ^(S_IF<StmtNode.If>["S_IF"] stmtIfBlock stmtsElif stmtElse?)
    ;
stmtIfBlock
    :    '(' expr ')' (NLL)? stmtBlock -> expr stmtBlock
    ;
stmtsElif
    :    stmtElif* -> ^(LIST<ListNode>["LIST"] stmtElif*)
    ;
stmtElif
    :    'elif' stmtIfBlock -> ^(S_ELIF<StmtNode.Elif>["S_ELIF"] stmtIfBlock)
    ;
stmtElse
    :    'else' (NLL)? stmtBlock -> stmtBlock
    ;
stmtProvided
    :    'provided' '(' expr ')' (NLL)? stmtBlock (stmtElse)?
        -> ^(S_PROVIDED<StmtNode.Provided>["S_PROVIDED"] expr stmtBlock stmtElse?)
    ;
stmtWhile
    :    'while' '('expr')' stmtWhile2 -> ^(S_WHILE<StmtNode.While>["S_WHILE"] expr stmtWhile2) //// (NLL)? stmtBlock 
    ;
stmtWhile2
    :	';' (NLL) -> ^(S_BLOCK<StmtNode.Block>["S_BLOCK"] LIST<ListNode>["LIST"])
    |        (NLL!)? stmtBlock 
    ;
stmtDecl
   :     stmtDeclAttr varDecl delim    -> ^(S_DECL<StmtNode.Decl>["S_DECL"] varDecl)
   ;
stmtDeclAttr
    :    (     'const' { typeMods.add(Flags.CONST); }
        |     'volatile' { typeMods.add(Flags.VOLATILE); }
        |        t='host' { ParseUnit.current().reportError($t, "invalid function local variable attribute"); } 
        )*
    ;
fieldDeclaration    
@init {
    stmtFlags = EnumSet.noneOf(Flags.class);
    typeMods = EnumSet.noneOf(Flags.class);
    stmtFlags.add(Flags.FIELD);
}
   :     ('new' | 'host' 'new')=> varDeclarationNew
   |     varAttr varDecl delim    -> varDecl 
   ;
varDeclaration   
@init {
    typeMods = EnumSet.noneOf(Flags.class);
    stmtFlags = EnumSet.noneOf(Flags.class);
} 
@after{
    typeMods = EnumSet.noneOf(Flags.class);
}
   :     varAttr varDecl delim    -> varDecl
   ;
varAttr
    :    (     'const' { typeMods.add(Flags.CONST); }
        |     'volatile' { typeMods.add(Flags.VOLATILE); }
        |       'host' { typeMods.add(Flags.HOST); } 
        )*
    ;
varDecl
scope {
  // Use 'typ' to rewrite the tree so that for AST x, 
  // 'int x' and 'int y = 3, x, z' has the same structure.
  Object typ; //CommonTree typ; only Object works, for some reason.
}
@init {
    $varDecl::typ = null;
    stmtFlags.addAll(typeMods);
}
    :    (typeName IDENT (ASSIGN)) => varDeclList
    |    (typeName IDENT '[') => varArray 
    |    (typeName '[' ) => varArray2
    |     (('(')? typeName '(' ) => varFcnRef 
    |     ( ('(') typeName typeName '(' ) => varFcnRef2
    |     (typeName varInit) => varDeclList  // unnecessary?
    ;
varDeclarationNew        //  these can't be in a varDeclList
@init {
    typeMods = EnumSet.noneOf(Flags.class);
    stmtFlags = EnumSet.noneOf(Flags.class);
    String ctor = ""; 
} 
@after{
    typeMods = EnumSet.noneOf(Flags.class);
}
    :    'new' qualName IDENT fcnArgumentList  delim // declaration of an instance ('new')
             { 
                  stmtFlags.add(Flags.NEW); 
                  ctor = ParseUnit.CTOR_CLASS_TARGET; 
             } 
             -> ^(D_VAR<DeclNode.TypedMember>["D_VAR", stmtFlags] ^(T_USR<TypeNode.Usr>["T_USR", typeMods] qualName)
                 IDENT ^(E_NEW<ExprNode.New>["E_NEW"] 
                              ^(E_CALL<ExprNode.Call>["E_CALL"] 
                               ^(E_IDENT<ExprNode.Ident>["E_IDENT"] IDENT[$qualName.text + "." + ctor]) 
                                fcnArgumentList))                                  
                  )
   | ('host' 'new') => 'host' 'new' qualName IDENT fcnArgumentList  delim 
             {   stmtFlags.add(Flags.NEW); 
                  stmtFlags.add(Flags.HOST);
                  ctor = ParseUnit.CTOR_CLASS_HOST;
                  typeMods.add(Flags.HOST);
             } 
             -> ^(D_VAR<DeclNode.TypedMember>["D_VAR", stmtFlags] ^(T_USR<TypeNode.Usr>["T_USR", typeMods] qualName)
                 IDENT ^(E_NEW<ExprNode.New>["E_NEW"] 
                              ^(E_CALL<ExprNode.Call>["E_CALL"] 
                               ^(E_IDENT<ExprNode.Ident>["E_IDENT"] IDENT[$qualName.text + "." + ctor]) 
                                fcnArgumentList))                                  
                  )

    ;
varFcnRef
    :     ( ('(') typeName fcnRefTypeList (')') IDENT (ASSIGN expr)?
            |  typeName fcnRefTypeList  IDENT (ASSIGN expr)? )
        -> ^(D_FCN_REF<DeclNode.FcnRef>["D_FCN_REF", stmtFlags] typeName fcnRefTypeList IDENT expr?) 
    ;
varFcnRef2
    :     '(' rtnType typeName fcnRefTypeList ')' IDENT (ASSIGN expr)?
        { stmtFlags.add(Flags.FCN_REF_RTN); } // has a return type specified
        -> ^(D_FCN_REF<DeclNode.FcnRef>["D_FCN_REF", stmtFlags] typeName fcnRefTypeList IDENT rtnType expr?) 
    ;            
rtnType 
    :    typeName
    ;

fcnRefTypeList
    :     '(' fcnRefTypes ')' -> fcnRefTypes
    ;
fcnRefTypes
    :    typeName (',' typeName)* 
        -> ^(LIST<ListNode>["LIST"] typeName+)
    |    -> ^(LIST<ListNode>["LIST"])
    ;
varArray
scope{
    Object varArrSpec;
    Object typArrSpec;
}
@after {
         ((CommonTree) $varArray::typArrSpec).addChild(((CommonTree) $varArray::varArrSpec));                
}
    :    typeNameArray { $varArray::typArrSpec = $typeNameArray.tree; }
        IDENT 
        varArraySpec { $varArray::varArrSpec = $varArraySpec.tree; } 
        varArrayInit[stmtFlags]?
            ->  ^(D_ARR<DeclNode.Arr>["D_ARR", stmtFlags] 
                typeNameArray 
                IDENT varArraySpec varArrayInit?)
    ;    
varArray2
scope{
    Object varArrSpec;
    Object typArrSpec;
}
@after {
         ((CommonTree) $varArray2::typArrSpec).addChild(((CommonTree) $varArray2::varArrSpec));                
}
    :   typeNameArray { $varArray2::typArrSpec = $typeNameArray.tree; }
        varArraySpec  { $varArray2::varArrSpec = $varArraySpec.tree; } 
        IDENT 
        varArrayInit[stmtFlags]?
            ->  ^(D_ARR<DeclNode.Arr>["D_ARR", stmtFlags] 
                typeNameArray 
                IDENT varArraySpec varArrayInit?)
    ;    
varArraySpec
    :    ('[' varDim ']')+    ->   ^(LIST<ListNode>["LIST"] varDim+)
    ;
varArrayInit[EnumSet<Flags> f]
    :    (ASSIGN initializer)                 -> initializer
    |    (PEG initializer) {f.add(Flags.PEG);}     -> initializer
    ;
varDim
@init {
  EnumSet<LitFlags> fl = EnumSet.noneOf(LitFlags.class);
  fl.add(LitFlags.NUM); fl.add(LitFlags.INT);
}
    :      expr  
    // the array without dimension could be useful (pegging an array to some memory) but not implemented. 
    |     -> ^(E_CONST<ExprNode.Const>["E_CONST", fl] INT_LIT[ParseUnit.ARRAY_WITHOUT_DIMENSION]) // an array without dimensions (in c, flexible)
    ;
// NOTE this had an optional trailing ',' before the final curly that I deleted for ambiguities
initializer   
    :  expr 
    |  ('new') => exprNew
    |  braceOpenNLL initializer_list braceNLLClose  
    ;
catch [NoViableAltException ne] {  
        ParseUnit.current().reportFailure("Invalid token between '{'...'}'.  Check initializer list for improper newline location. In lists, newlines are only valid after comma.");
    }
initializer_list
    :    initializer (',' NLL? initializer )*  -> ^(E_VEC<ExprNode.Vec>["E_VEC"]  ^(LIST<ListNode>["LIST"] initializer+))
    ;

braceNLLClose
    :   (NLL BRACE_CL) => NLL! BRACE_CL!
    |   BRACE_CL!
    ;

varDeclList  // int x, y=3, z=3, a
@init {
    assert $varDecl::typ != null;
}  
    :    varBuiltInType! {$varDecl::typ = $varBuiltInType.tree; } varListBuiltInType
    |    userTypeName! {$varDecl::typ = $userTypeName.tree; } varListUserDefType
    ;    
varBuiltInType
    :    builtinType -> ^(T_STD<TypeNode.Std>["T_STD", stmtFlags] builtinType)
    ;
varListBuiltInType
    :    varInit2 (','! varInit2)*     // -> ^(LIST<ListNode>["LIST"] varInit2+) doesn't work with unit features, which expects decls not list
    ;
varListUserDefType
    :    varInit (','! varInit)*     // -> ^(LIST<ListNode>["LIST"] varInit+)
    ;
varInit2        // built in type
    :    (IDENT ASSIGN)=> IDENT ASSIGN expr
        -> ^(D_VAR<DeclNode.Var>["D_VAR", stmtFlags] {$varDecl::typ} 
            IDENT expr)
    |     IDENT
        -> ^(D_VAR<DeclNode.Var>["D_VAR", stmtFlags] {$varDecl::typ} IDENT)
    ;
  
varInit     // user defined type
    :    (IDENT BIND)=> IDENT BIND userTypeName { stmtFlags.add(Flags.PROTOCOL_MEMBER);  stmtFlags.add(Flags.BIND); }    
        -> ^(D_VAR<DeclNode.TypedMember>["D_VAR", stmtFlags] {$varDecl::typ} IDENT ^( E_TYP<ExprNode.Typ>["E_TYP"] userTypeName )?)
    |     (IDENT PEG)=> IDENT PEG expr { stmtFlags.add(Flags.PEG); }    
        -> ^(D_VAR<DeclNode.TypedMember>["D_VAR", stmtFlags] {$varDecl::typ} IDENT expr?)
    |     (IDENT ASSIGN 'new')=>IDENT ASSIGN exprNew 
        -> ^(D_VAR<DeclNode.TypedMember>["D_VAR", stmtFlags] {$varDecl::typ} 
            IDENT exprNew)
    |     (IDENT ASSIGN)=>IDENT ASSIGN (expr)
        -> ^(D_VAR<DeclNode.TypedMember>["D_VAR", stmtFlags] {$varDecl::typ} 
            IDENT expr)
    |    IDENT 
        -> ^(D_VAR<DeclNode.TypedMember>["D_VAR", stmtFlags] {$varDecl::typ} IDENT)
    ;

builtinType  returns [EnumSet<LitFlags> f]
    :   'bool'          {$f = EnumSet.noneOf(LitFlags.class); $f.add(LitFlags.BOOL);}
    |   'byte'          {$f = EnumSet.noneOf(LitFlags.class); $f.add(LitFlags.CHR);}
    |   'int8'           {$f = EnumSet.noneOf(LitFlags.class); $f.add(LitFlags.NUM);}
    |   'int16'         {$f = EnumSet.noneOf(LitFlags.class); $f.add(LitFlags.NUM);}
    |   'int32'         {$f = EnumSet.noneOf(LitFlags.class); $f.add(LitFlags.NUM);}
    |   'real'           {$f = EnumSet.noneOf(LitFlags.class); $f.add(LitFlags.NUM);}
    |   'string'        {$f = EnumSet.noneOf(LitFlags.class); $f.add(LitFlags.STR);}
    |   'uint8'         {$f = EnumSet.noneOf(LitFlags.class); $f.add(LitFlags.NUM);}
    |   'uint16'       {$f = EnumSet.noneOf(LitFlags.class); $f.add(LitFlags.NUM);}
    |   'uint32'       {$f = EnumSet.noneOf(LitFlags.class); $f.add(LitFlags.NUM);}
    ;
    
qualName 
scope {
  Object qtree; 
  String s;
}
@init {
    $qualName::qtree = null;
    $qualName::s = "";
}
@after {  // moved handleIntrinsics() code inline for performance
        if ($qualName.tree != null && $qualName.tree.getText().length() > 0 &&
            $qualName.tree.getText().indexOf('.') != -1) {

           switch ( $qualName.tree.getText().charAt(0)) {
           case 'p':
           //  handleIntrinsics((CommonTree) $qualName.tree);
             String s = $qualName.tree.getText();             
             if (s.substring(0, s.indexOf('.')).equals("pollen")) {
                s = s.replaceFirst("\\.", "__");
                $qualName.tree.getToken().setText(s);
             }       
             break;
           default:
             break;
           }
        }      
}      
    :	 IDENT (qualNameList?)  -> IDENT[$IDENT.text + $qualName::s] 
    ;

qualNameList 
    :
    (   '.'!     
                IDENT! {$qualName::s += "." + $IDENT.text;}
        )+     
    ; 
            
arrayLit        // anonymous arrays
    :    '['    arrayLitList    ']'    -> ^(LIST<ListNode>["LIST"] arrayLitList)
    ;
arrayLitList
    :    arrayLitElem    (','    arrayLitElem)*    -> arrayLitElem+
    |    -> NIL
    ;
arrayLitElem
    :    primitiveLit    |    namedConstant
    ;
namedConstant
    :    qualName        // enforce to be const or enum member
    ;
boolLit
    : ('true' | 'false') { $primitiveLit::litFlags.add(LitFlags.BOOL);}
    ;
nullLit
    :    'null' {$primitiveLit::litFlags.add(LitFlags.NULL);}
    ;
numLit
@after {
    $primitiveLit::litFlags.add(LitFlags.NUM);
}
    :    INT_LIT {$primitiveLit::litFlags.add(LitFlags.INT);}    
    |     OCT_LIT {$primitiveLit::litFlags.add(LitFlags.OCT);}    
    |     REAL_LIT {$primitiveLit::litFlags.add(LitFlags.REAL);}    
    |     HEX_LIT  {$primitiveLit::litFlags.add(LitFlags.HEX);}    
    ;
// All literals should go through primitiveLit to clear / set LitFlags
primitiveLit 
scope {
    EnumSet<LitFlags> litFlags;
}
@init {
    $primitiveLit::litFlags = EnumSet.noneOf(LitFlags.class);
}
    :    boolLit -> ^(E_CONST<ExprNode.Const>["E_CONST", $primitiveLit::litFlags] boolLit)
    |    numLit  -> ^(E_CONST<ExprNode.Const>["E_CONST", $primitiveLit::litFlags] numLit)
    |    nullLit -> ^(E_CONST<ExprNode.Const>["E_CONST", $primitiveLit::litFlags] nullLit)
    |    STRING  {$primitiveLit::litFlags.add(LitFlags.STR);}  
       -> ^(E_CONST<ExprNode.Const>["E_CONST", $primitiveLit::litFlags] STRING)
    |    CHAR {$primitiveLit::litFlags.add(LitFlags.CHR);}  
        -> ^(E_CONST<ExprNode.Const>["E_CONST", $primitiveLit::litFlags] CHAR)
    ;
stmtInjection
    :    inject
        NLL    
        -> ^(S_INJ<StmtNode.Inject> ["S_INJ"] ^(E_INJ<ExprNode.Inject>["E_INJ"] inject))
    ;
// Here we synthesize nodes that split the injected code into pollen names and straight output code.
// The pollen names will be formatted for output.
inject
@init {
    BaseNode r = (BaseNode)adaptor.nil();
}
    :    c=INJECT  {           
                    $c.setText(getInject($c.getText()));
                       createInjectNodes(r, $c.getText());           
                }
        -> ^(LIST<ListNode>["LIST"] {r})
    ;
injectionCode
    :    inject
        -> ^(E_INJ<ExprNode.Inject>["E_INJ"]  inject) // don't consume delimiter
    ;
injectionDecl
    :    inject
                (NLL)
                 -> ^(D_INJ<DeclNode.Inject>["D_INJ"] ^(E_INJ<ExprNode.Inject>["E_INJ"] inject))
    ;
delim
    :    (SEMI NLL) => SEMI NLL  -> 
    |    (SEMI) ->
    |    (NLL)   -> 
    // Needed when the last stmt in a block ends with BRACE_CL (no NL or SEMI)
    // NOTE this cannot be used unless backtrack==true
    // |    ((NLL)? BRACE_CL) =>  (NLL)? -> 
    ;
    
// lexer
// convention: lexer rules are upper case.
IDENT
    :   I (I | D)*
    ;
HEX_LIT
    :    ('0x' | '0X') (H)+ (LU)?
    ;
OCT_LIT
    :    '0' O+
    ;
REAL_LIT
    :    D+ E ('l' | 'L')?
    |    D+ '.' D* (E)? ('l' | 'L')?
    ;
INT_LIT
    :    D+ (LU)? 
    ;    
CHAR
    :   '\'' (('\\' ~'\n') | ~('\\' | '\'' | '\n')) '\''
    ;
STRING
    :   '"' (('\\' ~'\n') | ~('\\' | '"' | '\n'))* '"'
    |     '\'' (('\\' ~'\n') | ~('\\' | '\'' | '\n'))+ '\''
    ;
WS
    :   (' ' | '\t')+  { $channel=HIDDEN; }
    ;

SL_COMMENT
    : '#' ~('\n'|'\r')*   { $channel=HIDDEN; }
    | '/''/' ~('\n'|'\r')*   { $channel=HIDDEN; }
    | ('---' ~('-')) => SLCOM3 ~('\n'|'\r')+  { $channel=HIDDEN; } // NOTE this rule embedded in COM does not work
    ;

INJECT
    : IJ_BEG ( options {greedy=false;} : .)* IJ_END
    ;

ML_COMMENT    
     // Note the first has to have a min of 4 dashes to disambig w/ sl_comment
     // --- comment    <= Otherwise THIS is a single line comment
     // ---            <= AFTER token emitted, this makes it a multiline  comment.
     // Note
     // '!-- comment --!' can be on one line but the '----' form cannot be because the NEWLINE disambiguates
    :   MULCOM ( options {greedy=false;} : . )*  '--!' (NEWLINE)* { $channel=HIDDEN; }
    |   '----' ('-')* WS? NEWLINE ( options {greedy=false;} : . )* '---' ('-')* (NEWLINE)* { $channel=HIDDEN; }
    ;

SEMI
    :   ';'
    ;
BRACE_OP
    : '{'
        {  braceOpenNLLLineNum.push(new Integer(state.tokenStartLine)); }
    ;
BRACE_CL
    : '}'   
            {
                if (!braceOpenNLLLineNum.empty()) {
                    if (state.tokenStartLine == braceOpenNLLLineNum.peek()) {
                        pollenLexer.fileName = fileName;
                        pollenLexer.lineNum = state.tokenStartLine;
                        Atom a = new Atom(NLL, "\n");
                        emit(a);   // create a delimiter to disambig grammar
                        a = new Atom(BRACE_CL, "}");
                        emit(a);    // the close brace
                    }
                    braceOpenNLLLineNum.pop();
                }
            }   
    ;

//NL :   ('\r')? ('\n'); 

// this sucks up comments into delimiters.
NLL   // cannot be hidden because a statement delimiter ;
 :   ( (NEWLINE) ( (WS)? NEWLINE)* ) WS? 
     (COM)*
 ;
fragment COM:
         { input.LA(1) < 48                          // 
           && ((char)input.LA(1) == '#') 
           || (((char)input.LA(1) == '/' || (char)input.LA(1) == '-' || (char)input.LA(1) == '!')
              && (((char)input.LA(1) == '/' && (char)input.LA(2) == '/')
                 || ((char)input.LA(1) == '-' && (char)input.LA(2) == '-' && (char)input.LA(3) == '-')
                 || ((char)input.LA(1) == '!' && (char)input.LA(2) == '-' && (char)input.LA(3) == '-')))
         }?=>
         (
              (   ('#')     =>    SL_COMMENT
                | ('/''/')  =>    SL_COMMENT
                | ('----')   =>   '----' ('-')* WS? NEWLINE ( options {greedy=false;} : . )* '---' ('-')*
                | ('---')   =>    SL_COMMENT 
                | ('!--')   =>    (MULCOM ( options {greedy=false;} : . )*  '--!')
              )
              (WS)? NEWLINE ( (WS)? NEWLINE)* WS?
         )
 ;
ILLEGAL_CHARACTER
    :   '\u0080'..'\uFFFF'
    ;
// fragments: never returned to the parser as a token
// NOTE lexer does not appear to like complement (~) of token fragments.
fragment I:       ('a'..'z'|'A'..'Z'|'_'|'$') ;
fragment D:        '0'..'9' ;
fragment O:             '0'..'7';
fragment H:        'a'..'f' | 'A'..'F' | '0'..'9' ;
fragment E:        ('E' | 'e') (PLUS | MINUS)? (D)+ ;
fragment LU:       'LU' | 'Lu' | 'lU' | 'lu' | 'UL' | 'uL' | 'Ul' | 'ul' | 'l' | 'u' | 'L' | 'U' ;
fragment NEWLINE:   '\r' '\n' | '\n' |'\r';
fragment MULCOM:     '!--';
fragment MULCOM1:    '----';
fragment SLCOM1:     '/''/';
fragment SLCOM2:     '#';
fragment SLCOM3:     '---';

INC         :    '++';
PLUS        :    '+';
DEC         :    ('--');
MINUS       :    ('-');
ASSIGN      :    '=';  // note ASSIGN must be first of eq ops or grammar error (won't be matched)
BIND        :    ':=';
ADD_EQ      :    '+=';
SUB_EQ      :    '-=';
MUL_EQ      :    '*=';
DIV_EQ      :    '\\=';
BITOR_EQ    :    '|=';
BITXOR_EQ   :    '^=';
BITAND_EQ   :    '&=';
RSHFT_EQ    :    '>>=';
LSHFT_EQ    :    '<<=';
MOD_EQ      :    '%=';
PEG         :    '@=';
EQ          :    '==';
NOT_EQ      :    '!=';
LT_EQ       :    '<=';
GT_EQ       :    '>=';
LOG_NOT     :    '!';
BIT_NOT     :    '~';
GT          :    '>';
LT          :    '<';
// injection blocks

IJ_BEG:     '+{';
IJ_END:     '}+';
/*
INJ_ID
    : ('\`')( options {greedy=false;} : .)* ('\`')
    ;
// must be last or it will be returned in place of tokens with less restricted utility
INJ_TXT
    : ~('\`')( options {greedy=false;} : .)* ~('\`')
    ;
*/
