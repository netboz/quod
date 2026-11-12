using Godot;

// Local native input adapter. The focused editor remains the only text/caret/
// selection/draft owner; this surface holds no copy of its contents.
public partial class SpatialGui
{
    PanelContainer keyboard=null!;
    Control? textTarget;
    long textGeneration;
    Button shiftKey=null!;
    bool Shifted=>shiftKey.ButtonPressed;
    public bool TextEntryActive=>textTarget!=null && keyboard.Visible;
    int KeyboardHeight=>keyboard?.Visible==true ? (int)Mathf.Ceil(keyboard.GetCombinedMinimumSize().Y)+16 : 0;
    bool TextEligible(Control? control)=>control!=null && IsInstanceValid(control) && !control.IsQueuedForDeletion() &&
        control.IsInsideTree() && control.GetViewport() is SubViewport viewport && Owns(viewport) && control.IsVisibleInTree() && control.FocusMode!=FocusModeEnum.None &&
        (control is LineEdit { Editable:true } || control is TextEdit { Editable:true });
    bool TextCurrent(Control? control,long generation)=>generation==textGeneration && control==textTarget && TextEligible(control) &&
        Spatial && control!.GetViewport().GuiGetFocusOwner()==control && !Surface.GetEmbeddedSubwindows().Concat(FormSurface.GetEmbeddedSubwindows()).Any(w=>w.Visible);

    // All shared text consumers use the native editability owner. Releasing a
    // newly disabled field also revokes queued keyboard input immediately.
    internal static void SetEditable(Control control,bool editable)
    {
        if(control is LineEdit line)line.Editable=editable;
        else if(control is TextEdit text)text.Editable=editable;
        if(!editable && control.HasFocus())control.ReleaseFocus();
    }
    void InitializeKeyboard()
    {
        keyboard=new() {Name="spatial-keyboard",Visible=false,Theme=workspaceTheme,MouseFilter=MouseFilterEnum.Stop};
        FormSurface.AddChild(keyboard);var column=new VBoxContainer();keyboard.AddChild(column);
        var header=new HBoxContainer();column.AddChild(header);
        header.AddChild(new Label {Text="AZERTY · local text",SizeFlagsHorizontal=SizeFlags.ExpandFill});
        KeyButton(header,"Hide",()=>EndTextInput(),"hide");
        // Same deliberately limited layout as the existing browser adapter.
        // Hardware/platform input remains available for other locales/symbols.
        foreach(string row in new[]{"1234567890","azertyuiop","qsdfghjklm","wxcvbn_","()[],:;'\"\\","=-+*/<>|!?%."}) {
            var keys=new HBoxContainer();column.AddChild(keys);
            foreach(char character in row) {
                string value=character.ToString();
                var key=KeyButton(keys,value,()=>SendTextKey(Key.None,(uint)(Shifted ? char.ToUpperInvariant(character) : character)),"char-"+(int)character);
                if(char.IsLetter(character))key.SetMeta("letter",value);
            }
        }
        var editing=new HBoxContainer();column.AddChild(editing);
        shiftKey=KeyButton(editing,"⇧",ToggleShift,"shift");shiftKey.ToggleMode=true;
        KeyButton(editing,"Space",()=>SendTextKey(Key.None,32),"space");
        KeyButton(editing,"⌫",()=>SendTextKey(Key.Backspace),"backspace");
        KeyButton(editing,"Del",()=>SendTextKey(Key.Delete),"delete");
        KeyButton(editing,"←",()=>SendTextKey(Key.Left),"left");
        KeyButton(editing,"→",()=>SendTextKey(Key.Right),"right");
        KeyButton(editing,"↶",()=>SendTextKey(Key.Z,0,true),"undo");
        KeyButton(editing,"↵",()=>SendTextKey(Key.Enter),"enter");
        keyboard.MinimumSizeChanged+=ResizeKeyboard;
        Surface.GuiFocusChanged+=WorkspaceFocusChanged;FormSurface.GuiFocusChanged+=FormFocusChanged;
    }
    void WorkspaceFocusChanged(Control? control){if(control!=null)FormSurface.GuiReleaseFocus();if(control!=null||textTarget?.GetViewport()==Surface)TextFocusChanged(control);}
    void FormFocusChanged(Control? control){if(control!=null)Surface.GuiReleaseFocus();if(control!=null||textTarget?.GetViewport()==FormSurface)TextFocusChanged(control);}
    Button KeyButton(Control row,string label,Action action,string name)
    {
        var key=new Button {Name="keyboard-"+name,Text=label,TooltipText=name.StartsWith("char-") ? label : name,FocusMode=FocusModeEnum.None,CustomMinimumSize=new(0,44),SizeFlagsHorizontal=SizeFlags.ExpandFill};row.AddChild(key);
        Control? target=null;long generation=0;bool checkedBefore=false;
        key.ButtonDown+=()=>{target=textTarget;generation=textGeneration;checkedBefore=key.ButtonPressed;};
        key.Pressed+=()=>{
            var expected=target;long incarnation=generation;
            // Native toggle precedes Pressed. Commit its indication only with
            // the same live-target validation as the corresponding command.
            if(key.ToggleMode)key.SetPressedNoSignal(checkedBefore);
            // Native mouse release finishes before another input event enters
            // its viewport. A replacement/focus loss revokes this continuation.
            Callable.From(()=>{if(keyboard.Visible && TextCurrent(expected,incarnation))action();}).CallDeferred();
        };
        return key;
    }
    void ToggleShift()
    {
        shiftKey.SetPressedNoSignal(!Shifted);
        foreach(var key in keyboard.FindChildren("*","Button",true,false).OfType<Button>().Where(b=>b.HasMeta("letter"))) {
            string letter=key.GetMeta("letter").AsString();key.Text=Shifted ? letter.ToUpperInvariant() : letter;
        }
    }
    void SendTextKey(Key code,uint unicode=0,bool control=false)
    {
        if(!TextCurrent(textTarget,textGeneration))return;
        var input=new InputEventKey {Keycode=code,Unicode=unicode,Pressed=true,CtrlPressed=control,ShiftPressed=Shifted&&unicode==0&&!control,WindowId=GetWindow().GetWindowId()};
        var viewport=textTarget!.GetViewport();viewport.PushInput(input,true);input.Pressed=false;viewport.PushInput(input,true);
    }
    void TextFocusChanged(Control? control)
    {
        if(!Spatial || !TextEligible(control)){EndTextInput();return;}
        if(control!=textTarget) {
            EndTextInput();textTarget=control;textGeneration++;
            control!.FocusExited+=EndTextInput;control.TreeExiting+=EndTextInput;control.VisibilityChanged+=CheckTextTarget;
            control.MinimumSizeChanged+=CheckTextTarget;
            // TextEdit has no editability signal. Its native setter queues a
            // redraw even when minimum size is unchanged; observe only this
            // focused control, not a per-frame field scan or readiness timer.
            control.Draw+=CheckTextTarget;
            if(control is LineEdit line)line.EditingToggled+=EditingToggled;
        }
        long expected=textGeneration;
        Callable.From(()=>{if(expected==textGeneration)RefreshKeyboard();}).CallDeferred();
    }
    void EditingToggled(bool editing) {if(!editing)EndTextInput();}
    void CheckTextTarget() {if(!TextCurrent(textTarget,textGeneration))EndTextInput();}
    void RefreshKeyboard()
    {
        if(pressed)return;
        if(!TextCurrent(textTarget,textGeneration)) {
            if(keyboard.Visible){keyboard.Hide();ResizeKeyboard();}return;
        }
        if(!keyboard.Visible){keyboard.Show();ResizeKeyboard();}
    }
    void ResizeKeyboard()
    {
        if(!IsInsideTree() || keyboard==null)return;
        ResizeSurface();
    }
    public void EndTextInput()
    {
        if(textTarget==null && keyboard?.Visible!=true)return;
        var previous=textTarget;textTarget=null;textGeneration++;
        if(previous!=null && IsInstanceValid(previous)) {
            previous.FocusExited-=EndTextInput;previous.TreeExiting-=EndTextInput;previous.VisibilityChanged-=CheckTextTarget;
            previous.MinimumSizeChanged-=CheckTextTarget;previous.Draw-=CheckTextTarget;if(previous is LineEdit line)line.EditingToggled-=EditingToggled;
        }
        // Revoke the target immediately, but retain geometry until the native
        // press that changed focus ends. Its release must use the same surface.
        if(keyboard!=null)RefreshKeyboard();
    }
}
